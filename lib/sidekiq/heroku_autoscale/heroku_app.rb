module Sidekiq
  module HerokuAutoscale

    class HerokuApp
      attr_reader :client, :app_name

      # Builds dyno managers based on configuration (presumably loaded from YAML)
      # Builds a manager per Heroku process, and keys each under their queue names. Ex:
      # { "default" => manager1, "high" => manager2, "low" => manager2 }
      def initialize(config)
        config = JSON.parse(JSON.generate(config), symbolize_names: true)

        api_token = config[:api_token] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN']
        @client = api_token ? PlatformAPI.connect_oauth(api_token) : nil

        @app_name = config[:app_name] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP']

        @processes = config[:processes].each_with_object({}) do |(name, opts), memo|
          manager = ProcessManager.new(api_client: @client, app_name: @app_name, process_name: name, **opts)
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

      def queue_names
        @processes.keys
      end

      def process_names
        @processes.values.map(&:process_name).uniq
      end

      def process_for_queue(queue_name)
        @processes[queue_name] || @processes['*']
      end

      def process_by_name(process_name)
        @processes.values.detect { |f| f.process_name == process_name }
      end
    end

  end
end