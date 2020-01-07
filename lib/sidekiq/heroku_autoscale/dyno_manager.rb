require 'platform-api'
require_relative 'queue_system'
require_relative 'scale_strategy'

module Sidekiq
  module HerokuAutoscale

    class DynoManager

      # Builds dyno managers based on configuration (presumably loaded from YAML)
      # Builds a manager per Heroku process, and keys each under their queue names. Ex:
      # { "default" => manager1, "high" => manager2, "low" => manager2 }
      def self.build_from_config(config)
        config = JSON.parse(JSON.generate(config), symbolize_names: true)
        token = config[:api_token] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN']
        app = config[:app_name] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP']

        config[:processes].each_with_object({}) do |(name, opts), memo|
          manager = DynoManager.new(api_token: token, app_name: app, process_name: name, **opts)
          manager.queue_system.watch_queues.each do |queue_name|
            # a queue may only be managed by a single heroku process type (to avoid scaling conflicts)
            # thus, raise an error over duplicate queue names or when "*" isn't exclusive
            if memo.key?(queue_name) || memo.key?('*') || (queue_name == '*' && memo.keys.any?)
              raise ArgumentError, 'watched queues must be exclusive to a single heroku process'
            end
            memo[queue_name] = manager
          end
        end
      end

      attr_reader :client, :app_name, :process_name

      attr_accessor :throttle, :quiet_buffer, :minimum_uptime
      attr_accessor :last_update, :quieted_at, :startup_at
      attr_accessor :queue_system, :scale_strategy

      # @param [String] process_name process process_name this scaler controls
      # @param [String] token Heroku OAuth access token
      # @param [String] app_name Heroku app_name name
      def initialize(
        api_token:,
        app_name:,
        process_name: 'worker',
        system: {},
        scale: {},
        throttle: 10,
        quiet_buffer: 10,
        minimum_uptime: 10
      )
        @client = PlatformAPI.connect_oauth(api_token)
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
      def sync_touch!
        if cached_touch = ::Sidekiq.redis { |c| c.get(cache_key(:touch)) }
          cached_touch = Time.parse(cached_touch)
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
      # no formations changes are allowed during a quiet window.
      # once the quiet buffer has expired, scaling occurs and new targets may be set.
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
          @quieted_to = quietdown[0]
          @quieted_at = Time.parse(quietdown[1])
          @startup_at ||= @quieted_at
          return true
        end
        false
      end

      # wrapper for throttling the upscale process (client)
      # polling runs until the next update has been called.
      def wait_for_update!(request_time=nil)
        return true if updated_since?(request_time)
        return false if throttled?
        return false if sync_touch! && throttled?
        update!
        true
      end

      # wrapper for polling the downscale process (server)
      # polling runs until an update returns zero dynos.
      def wait_for_shutdown!(request_time=nil)
        return false if updated_since?(request_time)
        return false if throttled?
        return false if sync_touch! && throttled?
        count = update!
        count.zero? && fulfills_uptime?
      end

      def update!(current=nil, target=nil)
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
            # do not return...
            # allows downscale conditions to be checked
            # during the same update cycle
          end
        end

        # downscale
        if quieting? && fulfills_quietdown? && fulfills_uptime?
          count = @quieted_to
          set_dyno_count(count)
          stop_quietdown
          return count
        end

        current
      end

      def exception_handler
        @exception_handler ||= lambda do |ex|
          p ex
          puts ex.backtrace
        end
      end

      attr_writer :exception_handler

    private

      def cache_key(action)
        "#{ self.class.name.gsub('::', '/') }/#{ action }/#{ process_name }"
      end

      def get_dyno_count
        @client.formation.list(app_name)
          .select { |item| item['type'] == process_name }
          .map { |item| item['quantity'] }
          .reduce(0, &:+)
      rescue Excon::Errors::Error, Heroku::API::Errors::Error => e
        exception_handler.call(e)
        0
      end

      def set_dyno_count(n)
        @client.formation.update(app_name, process_name, { quantity: n })
      rescue Excon::Errors::Error, Heroku::API::Errors::Error => e
        exception_handler.call(e)
      end
    end

  end
end
