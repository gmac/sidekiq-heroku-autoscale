require 'platform-api'

module Sidekiq
  module HerokuAutoscale

    class ProcessManager
      attr_reader :client, :app_name, :process_name, :quieted_to

      attr_accessor :throttle, :quiet_buffer, :minimum_uptime
      attr_accessor :last_update, :quieted_at, :startup_at
      attr_accessor :queue_system, :scale_strategy

      # @param [String] process_name process process_name this scaler controls
      # @param [String] token Heroku OAuth access token
      # @param [String] app_name Heroku app_name name
      def initialize(
        app_name:,
        api_client: nil,
        process_name: 'worker',
        system: {},
        scale: {},
        throttle: 10,
        quiet_buffer: 10,
        minimum_uptime: 10
      )
        @client = api_client
        @app_name = app_name
        @process_name = process_name.to_s
        @queue_system = QueueSystem.new(system)
        @scale_strategy = ScaleStrategy.new(scale)

        @throttle = throttle
        @last_update = nil

        @quieted_to = nil
        @quieted_at = nil
        @quiet_buffer = quiet_buffer

        @startup_at = nil
        @minimum_uptime = minimum_uptime
      end

      # check if a probe time is newer than the last update
      def updated_since?(timestamp)
        timestamp && @last_update && @last_update > timestamp
      end

      # check if last update falls within the throttle window
      def throttled?
        @last_update && Time.now.utc < @last_update + @throttle
      end

      # caches last-update timestamp so it may propagate across processes
      def touch(at=Time.now.utc)
        @last_update = at
        ::Sidekiq.redis { |c| c.setex(cache_key(:touch), @throttle, @last_update.to_s) }
      end

      # sync the last cached touch timestamp.
      # returns true when a value is assimilated
      def sync_touch
        if cached_touch = ::Sidekiq.redis { |c| c.get(cache_key(:touch)) }
          cached_touch = Time.parse(cached_touch).utc
          if !@last_update || @last_update < cached_touch
            @last_update = cached_touch
            return true
          end
        end
        false
      end

      # checks if the system is downscaling
      # no other scaling is allowed during a cooling period
      def quieting?
        @quieted_to && @quieted_at
      end

      def fulfills_quietdown?
        @quieted_at && Time.now.utc >= @quieted_at + @quiet_buffer
      end

      # checks if minimum observation uptime has been fulfilled
      def fulfills_uptime?
        @startup_at && Time.now.utc >= @startup_at + @minimum_uptime
      end

      # starts a quietdown period in which excess workers are quieted
      # no formation changes are allowed during a quietdown window.
      def quietdown(to=0)
        @quieted_to = [0, to].max
        @quieted_at = Time.now.utc
        @startup_at ||= @quieted_at
        unless queue_system.quietdown!(@quieted_to)
          # omit quiet buffer if no workers were actually quieted
          # allows direct downscaling without buffer delay
          # (though uptime buffer may still have an effect)
          @quieted_at -= (@quiet_buffer + 1)
        end
        ::Sidekiq.redis { |c| c.set(cache_key(:quietdown), [@quieted_to, @quieted_at.to_s]) }
      end

      # purges quietdown configuration
      def stop_quietdown
        @quieted_to = @quieted_at = nil
        ::Sidekiq.redis { |c| c.del(cache_key(:quietdown)) }
      end

      # syncs quietdown configuration across processes
      def sync_quietdown
        if quietdown = ::Sidekiq.redis { |c| c.get(cache_key(:quietdown)) }
          quietdown = JSON.parse(quietdown)
          @quieted_to = quietdown[0]
          @quieted_at = Time.parse(quietdown[1]).utc
          @startup_at ||= @quieted_at
          return true
        end
        false
      end

      # wrapper for throttling the upscale process (client)
      # polling runs until the next update has been called.
      def wait_for_update!(request_time=nil)
        return true if updated_since?(request_time)
        return false if throttled? || (sync_touch && throttled?)
        update!
        true
      end

      # wrapper for polling the downscale process (server)
      # polling runs until an update returns zero dynos.
      def wait_for_shutdown!(request_time=nil)
        return false if throttled? || (sync_touch && throttled?)
        dynos = update!
        dynos.zero? && fulfills_uptime?
      end

      def update!(current=nil, target=nil)
        puts "**UPDATE #{ process_name }"
        touch
        current ||= get_dyno_count

        # set startup time when unset yet scaled
        # (probably an initial update)
        @startup_at ||= Time.now.utc if current > 0

        # sync cached quietdown settings from other processes,
        # then break potential gridlock of quieting + nothing running
        sync_quietdown
        stop_quietdown if current.zero? && quieting?

        # No changes are allowed while quieting...
        # the quieted dyno needs to be removed (downscaled)
        # before making other changes to the formation.
        unless quieting?
          # select a new scale target to shoot for
          # (provides a trajectory, not necessarily a destination)
          target ||= scale_strategy.call(queue_system)

          # idle
          if current == target
            return current

          # upscale
          elsif current < target
            @startup_at ||= Time.now.utc
            set_dyno_count(target)
            return target

          # quietdown
          elsif current > target
            quietdown(current - 1)
            # do NOT return...
            # allows downscale conditions to run during the same update
          end
        end

        # downscale
        if quieting? && fulfills_quietdown? && fulfills_uptime?
          dynos = @quieted_to
          set_dyno_count(dynos)
          stop_quietdown
          return dynos
        end

        current
      end

    private

      def class_key
        self.class.name.gsub('::', '/').downcase
      end

      def cache_key(action)
        "#{ class_key }/#{ action }/#{ process_name }"
      end

      def get_dyno_count
        if @client.present?
          count = @client.formation.list(app_name)
            .select { |item| item['type'] == process_name }
            .map { |item| item['quantity'] }
            .reduce(0, &:+)
          set_cached_dyno_count(count)
        else
          get_cached_dyno_count
        end
      rescue StandardError => e
        ::Sidekiq::HerokuAutoscale.exception_handler.call(e)
        set_cached_dyno_count(0)
      end

      def set_dyno_count(n)
        if @client.present?
          @client.formation.update(app_name, process_name, { quantity: n })
        end

        set_cached_dyno_count(n)
      rescue StandardError => e
        ::Sidekiq::HerokuAutoscale.exception_handler.call(e)
        get_cached_dyno_count
      end

      def get_cached_dyno_count
        ::Sidekiq.redis { |c| c.hget(class_key, process_name) } || 0
      end

      def set_cached_dyno_count(n)
        ::Sidekiq.redis { |c| c.hset(class_key, process_name, n) }
        n
      end
    end

  end
end
