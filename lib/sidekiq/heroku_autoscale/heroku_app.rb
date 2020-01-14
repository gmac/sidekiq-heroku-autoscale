require 'platform-api'

module Sidekiq
  module HerokuAutoscale

    class HerokuApp
      attr_reader :app_name

      # Builds process managers based on configuration (presumably loaded from YAML)
      def initialize(config)
        config = JSON.parse(JSON.generate(config), symbolize_names: true)

        api_token = config[:api_token] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN']
        @app_name = config[:app_name] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP']
        @client = api_token ? PlatformAPI.connect_oauth(api_token) : nil

        @processes_by_name = {}
        @processes_by_queue = {}

        config[:processes].each_pair do |name, opts|
          process = Process.new(app_name: @app_name, name: name, client: @client, **opts)
          @processes_by_name[name] = process

          process.queue_system.watch_queues.each do |queue_name|
            # a queue may only be managed by a single heroku process type (to avoid scaling conflicts)
            # thus, raise an error over duplicate queue names or when "*" isn't exclusive
            if @processes_by_queue.key?(queue_name) || @processes_by_queue.key?('*') || (queue_name == '*' && @processes_by_queue.keys.any?)
              raise ArgumentError, 'watched queues must be exclusive to a single heroku process'
            end
            @processes_by_queue[queue_name] = process
          end
        end
      end

      def live?
        !!@client
      end

      def processes
        @processes_by_name.values
      end

      def process_names
        @processes_by_name.keys
      end

      def queue_names
        @processes_by_queue.keys
      end

      def process_by_name(process_name)
        @processes_by_name[process_name]
      end

      def process_for_queue(queue_name)
        @processes_by_queue[queue_name] || @processes_by_queue['*']
      end

      def stats
        @processes_by_name.values.each_with_object({}) { |p, m| m[p.name] = p.dynos }
      end
    end

  end
end