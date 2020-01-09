module Sidekiq
  module HerokuAutoscale

    class FormationManager
      # Builds dyno managers based on configuration (presumably loaded from YAML)
      # Builds a manager per Heroku process, and keys each under their queue names. Ex:
      # { "default" => manager1, "high" => manager2, "low" => manager2 }
      def self.build_from_config(config)
        config = JSON.parse(JSON.generate(config), symbolize_names: true)

        processes = config[:processes].each_with_object({}) do |(name, opts), memo|
          manager = ProcessManager.new(api_token: config[:api_token], app_name: config[:app_name], process_name: name, **opts)
          manager.queue_system.watch_queues.each do |queue_name|
            # a queue may only be managed by a single heroku process type (to avoid scaling conflicts)
            # thus, raise an error over duplicate queue names or when "*" isn't exclusive
            if memo.key?(queue_name) || memo.key?('*') || (queue_name == '*' && memo.keys.any?)
              raise ArgumentError, 'watched queues must be exclusive to a single heroku process'
            end
            memo[queue_name] = manager
          end
        end

        new(processes)
      end

      def initialize(processes)
        @processes = processes
      end

      def queue_names
        @processes.keys
      end

      def process_names
        @processes.values.map(&:process_name)
      end

      def process_for_queue(queue_name)
        @processes[queue_name] || @processes['*']
      end

      def process_by_name(process_name)
        @processes.values.detect { |f| f.process_name == process_name }
      end

      def logger=(logger)
        @processes.values.each { |f| f.logger = logger }
      end

      def exception_handler=(handler)
        @processes.values.each { |f| f.exception_handler = handler }
      end
    end

  end
end