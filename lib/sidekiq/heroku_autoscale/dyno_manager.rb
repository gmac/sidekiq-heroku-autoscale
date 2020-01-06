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
      attr_reader :queue_system, :scale_strategy

      attr_accessor :throttle, :last_update, :quiet_buffer, :minimum_uptime

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

        @startup_at = nil
        @minimum_uptime = minimum_uptime

        @quietdown_to = nil
        @quietdown_at = nil
        @quiet_buffer = quiet_buffer
      end

      # check if a probe time is newer than the last update
      def updated_since?(timestamp)
        timestamp && @last_update && @last_update > timestamp
      end

      # check if last update falls within the throttle window
      def throttled?
        @last_update && Time.now.utc - @last_update <= @throttle
      end

      # checks if the system is downscaling
      # no other scaling is allowed during a cooling period
      def quieting?
        !!@quietdown_to
      end

      def fulfills_quietdown?
        quieting? && @quietdown_at && Time.now.utc >= @quietdown_at + @quiet_buffer
      end

      # checks if minimum observation uptime has been fulfilled
      def fulfills_uptime?
        @startup_at && Time.now.utc >= @startup_at + @minimum_uptime
      end

      # caches last-update timestamp so it may propagate across processes
      def touch(timestamp=nil)
        @last_update = timestamp || Time.now.utc
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

      # wrapper for throttling the upscale process (client)
      # polling runs until the next update! has been called.
      def wait_for_update!(request_time=nil)
        return true if updated_since?(request_time)
        return false if throttled?
        return false if sync_touch! && throttled?
        update!
        true
      end

      # wrapper for polling the downscale process (server)
      # polling runs until an update! returns zero dynos.
      def wait_for_shutdown!(request_time=nil)
        return false if updated_since?(request_time)
        return false if throttled?
        return false if sync_touch! && throttled?
        count = update!
        count.zero? && fulfills_uptime?
      end

      def update!
        touch
        target = scale_strategy.call(queue_system)
        current = get_dyno_count

        # set startup time when unset yet scaled
        # (probably an initial update)
        if !@startup_at && current > 0
          @startup_at = Time.now.utc
        end

        # idle
        if current == target || quieting?
          return current

        # upscale
        elsif current < target
          @startup_at ||= Time.now.utc
          set_dyno_count(target)
          return target

        # quietdown
        elsif current > target
          @quietdown_to = [0, current - 1].max
          @quietdown_at = Time.now.utc
          unless sys.quietdown!(@quietdown_to)
            # omit quiet buffer if no workers were quieted
            # allows the program to directly downscale.
            @quietdown_at -= @quiet_buffer
          end
        end

        # downscale
        if fulfills_uptime? && fulfills_quietdown?
          count = @quietdown_to
          set_dyno_count(count)
          @quietdown_to = nil
          @quietdown_at = nil
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
