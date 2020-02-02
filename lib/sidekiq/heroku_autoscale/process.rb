module Sidekiq
  module HerokuAutoscale

    class Process
      WAKE_THROTTLE = PollInterval.new(:wait_for_update!, before_update: 2)
      SHUTDOWN_POLL = PollInterval.new(:wait_for_shutdown!, before_update: 10)

      attr_reader :app_name, :name, :throttle, :history, :client
      attr_reader :queue_system, :scale_strategy

      attr_accessor :active_at, :updated_at, :quieted_at
      attr_accessor :dynos, :quieted_to, :quiet_buffer

      def initialize(
        name: 'worker',
        app_name: nil,
        client: nil,
        throttle: 10, # 10 seconds
        history: 3600, # 1 hour
        quiet_buffer: 10,
        system: {},
        scale: {}
      )
        @app_name = app_name || name.to_s
        @name = name.to_s
        @client = client
        @queue_system = QueueSystem.new(system)
        @scale_strategy = ScaleStrategy.new(scale)

        @dynos = 0
        @active_at = nil
        @updated_at = nil
        @quieted_at = nil
        @quieted_to = nil

        @throttle = throttle
        @history = history
        @quiet_buffer = quiet_buffer
      end

      def status
        if shutting_down?
          'stopping'
        elsif quieting?
          'quieting'
        elsif @dynos > 0
          'running'
        else
          'stopped'
        end
      end

      # request a throttled update
      def ping!
        @active_at = Time.now.utc
        if ::Sidekiq.server?
          # submit the process for runscaling (up or down)
          # the process is polled until shutdown occurs
          SHUTDOWN_POLL.call(self)
        else
          # submits the process for upscaling (wake up)
          # the process is polled until an update is run
          WAKE_THROTTLE.call(self)
        end
      end

      # checks if the system is downscaling
      # no other scaling is allowed during a cooling period
      def quieting?
        !!(@quieted_to && @quieted_at)
      end

      def shutting_down?
        quieting? && @quieted_to.zero?
      end

      def fulfills_quietdown?
        !!(@quieted_at && Time.now.utc >= @quieted_at + @quiet_buffer)
      end

      # check if a probe time is newer than the last update
      def updated_since_last_activity?
        !!(@active_at && @updated_at && @updated_at > @active_at)
      end

      # # check if last update falls within the throttle window
      def throttled?
        !!(@updated_at && Time.now.utc < @updated_at + @throttle)
      end

      # starts a quietdown period in which excess workers are quieted
      # no formation changes are allowed during a quietdown window.
      def quietdown(to=0)
        quiet_to = [0, to].max
        quiet_at = Time.now.utc
        unless queue_system.quietdown!(quiet_to)
          # omit quiet buffer if no workers were actually quieted
          # allows direct downscaling without buffer delay
          # (though uptime buffer may still have an effect)
          quiet_at -= (@quiet_buffer + 1)
        end
        set_attributes(quieted_to: quiet_to, quieted_at: quiet_at)
      end

      # wrapper for throttling the upscale process (client)
      # polling runs until the next update has been called.
      def wait_for_update!
        # resolve (true) when already updated by another process
        # keep waiting (false) when:
        # - redundant updates are called within the throttle window
        # - the system has been fully quieted and must shutdown before upscaling
        return true if updated_since_last_activity?
        return false if throttled?

        # first round of checks use local (process-specific) settings
        # now hit the redis cache and double check settings from other processes
        sync_attributes
        return true if updated_since_last_activity?
        return false if throttled?

        update!
        true
      end

      # wrapper for monitoring the downscale process (server)
      # polling runs until an update returns zero dynos.
      def wait_for_shutdown!
        return false if throttled?

        sync_attributes
        return false if throttled?

        update!.zero?
      end

      # update the process with live dyno count from Heroku,
      # and then reassess workload and scale transitions.
      # this method shouldn't be called directly... just ping! it.
      def update!(current=nil, target=nil)
        current ||= fetch_dyno_count

        attrs = { dynos: current, updated_at: Time.now.utc }
        if current.zero?
          attrs[:quieted_to] = nil
          attrs[:quieted_at] = nil
        end
        set_attributes(attrs)

        # No changes are allowed while quieting...
        # the quieted dyno needs to be removed (downscaled)
        # before making other changes to the formation.
        unless quieting?
          # select a new scale target to shoot for
          # (provides a trajectory, not necessarily a destination)
          target ||= scale_strategy.call(queue_system)

          # idle
          if current == target
            ::Sidekiq.logger.info("IDLE at #{ target } dynos")
            return current

          # upscale
          elsif current < target
            return set_dyno_count!(target)

          # quietdown
          elsif current > target
            ::Sidekiq.logger.info("QUIET to #{ current - 1 } dynos")
            quietdown(current - 1)
            # do NOT return...
            # allows downscale conditions to run during the same update
          end
        end

        # downscale
        if quieting? && fulfills_quietdown?
          return set_dyno_count!(@quieted_to)
        end

        current
      end

      # gets a live dyno count from Heroku
      def fetch_dyno_count
        if @client
          @client.formation.list(app_name)
            .select { |item| item['type'] == name }
            .map { |item| item['quantity'] }
            .reduce(0, &:+)
        else
          @dynos
        end
      rescue StandardError => e
        ::Sidekiq::HerokuAutoscale.exception_handler.call(e)
        0
      end

      # sets the live dyno count on Heroku
      def set_dyno_count!(count)
        ::Sidekiq.logger.info("SCALE to #{ count } dynos")
        @client.formation.update(app_name, name, { quantity: count }) if @client
        set_attributes(dynos: count, quieted_to: nil, quieted_at: nil, history_at: Time.now.utc)
        count
      rescue StandardError => e
        ::Sidekiq::HerokuAutoscale.exception_handler.call(e)
        @dynos
      end

      # sets redis-cached process attributes
      def set_attributes(attrs)
        cache = {}
        prev_dynos = @dynos
        if attrs.key?(:dynos)
          cache['dynos'] = @dynos = attrs[:dynos]
        end
        if attrs.key?(:quieted_to)
          cache['quieted_to'] = @quieted_to = attrs[:quieted_to]
        end
        if attrs.key?(:quieted_at)
          @quieted_at = attrs[:quieted_at]
          cache['quieted_at'] = @quieted_at ? @quieted_at.to_i : nil
        end
        if attrs.key?(:updated_at)
          @updated_at = attrs[:updated_at]
          cache['updated_at'] = @updated_at ? @updated_at.to_i : nil
        end

        ::Sidekiq.redis do |c|
          c.pipelined do
            # set new keys, delete expired keys
            del, set = cache.partition { |k, v| v.nil? }
            c.hmset(cache_key, *set.flatten) if set.any?
            c.hdel(cache_key, *del.map(&:first)) if del.any?

            if attrs[:history_at]
              # set a dyno count history marker
              event_time = (attrs[:history_at].to_f / @throttle).floor * @throttle
              history_page = (attrs[:history_at].to_f / @history).floor * @history
              history_key = "#{ cache_key }:#{ history_page }"

              c.hmset(history_key, (event_time - @throttle).to_s, prev_dynos, event_time.to_s, @dynos)
              c.expire(history_key, @history * 2)
            end
          end
        end
      end

      # syncs configuration across process instances (dynos)
      def sync_attributes
        if cache = ::Sidekiq.redis { |c| c.hgetall(cache_key) }
          @dynos = cache['dynos'] ? cache['dynos'].to_i : 0
          @quieted_to = cache['quieted_to'] ? cache['quieted_to'].to_i : nil
          @quieted_at = cache['quieted_at'] ? Time.at(cache['quieted_at'].to_i).utc : nil
          @updated_at = cache['updated_at'] ? Time.at(cache['updated_at'].to_i).utc : nil
          return true
        end
        false
      end

      def cache_key
        [self.class.name.gsub('::', '/').downcase, app_name, name].join(':')
      end
    end

  end
end
