require 'platform-api'
require 'autoscaler/counter_cache_memory'

module Sidekiq
  module HerokuAutoscale

    class DynoManager

      # Builds dyno managers based on configuration (presumably loaded from YAML)
      # Builds a manager per Heroku process, and keys each under their queue names. Ex:
      # { "default" => manager1, "high" => manager2, "low" => manager2 }
      def self.build_from_config(config)
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

      attr_reader :client, :app_name, :process_name, :last_update
      attr_reader :queue_system, :scale_strategy

      attr_writer :exception_handler

      # @param [String] process_name process process_name this scaler controls
      # @param [String] token Heroku OAuth access token
      # @param [String] app_name Heroku app_name name
      def initialize(api_token:, app_name:, process_name: 'worker', system: {}, scale: {})
        @client = PlatformAPI.connect_oauth(token)
        @app_name = app_name
        @process_name = process_name
        @queue_system = QueueSystem.new(system)
        @scale_strategy = ScaleStrategy.new(scale)
        @throttle = 10
      end

      # Checks if the manager has never been updated,
      # or if the last update exceeds the throttle duration,
      # and assures that there's no cross-process
      def ready_for_update?
        # Check local configuration first to see if last update has expired
        expired_locally = !@last_update || Time.now.utc - @last_update >= @throttle
        return false unless expired_locally

        # Assimilate updates cached in redis that may have come from another process
        if cached_update = HerokuAutoscale.redis { |c| c.get(redis_key(:update)) }
          @last_update = cached_update
          return false
        end
        true
      end

      def throttle_update!
        return false unless ready_for_update?
        update!
        true
      end

      def update!
        @last_update = Time.now.utc
        HerokuAutoscale.redis { |c| c.setex(redis_key(:update), @throttle * 60, @last_update) }
        scale = scale_strategy.call(queue_system)
        if scale != get_dyno_count
          queue_system.quiet! if scale.zero?
          set_dyno_count(scale)
        end
      end

      def exception_handler
        @exception_handler ||= lambda do |ex|
          p ex
          puts ex.backtrace
        end
      end

    private

      def redis_key(action)
        "#{self.class.name.underscore}/#{action}/#{process_name}"
      end

      def get_dyno_count
        @client.formation.list(app_name)
          .select { |item| item['type'] == process_name }
          .map { |item| item['quantity'] }
          .reduce(0, &:+)
      rescue Excon::Errors::Error => e
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
