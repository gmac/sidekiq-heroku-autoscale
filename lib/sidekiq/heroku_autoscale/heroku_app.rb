require 'platform-api'

module Sidekiq
  module HerokuAutoscale

    class HerokuApp
      attr_reader :name, :throttle

      # Builds process managers based on configuration (presumably loaded from YAML)
      def initialize(config={})
        config = JSON.parse(JSON.generate(config), symbolize_names: true)

        api_token = config[:api_token] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN']
        @name = config[:app_name] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP']
        @throttle = config[:throttle] || 10
        @history = 60 * 60 # 1 hour
        @client = api_token ? PlatformAPI.connect_oauth(api_token) : nil

        @dyno_counts = {}
        @processes_by_name = {}
        @processes_by_queue = {}

        if processes = config[:processes]
          build_processes(processes)
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
        # base_time = (Time.now.utc.to_f / @throttle).floor * @throttle - @history
        # times = Array.new(@history / @throttle).each_with_index.map { |i| base_time + 10 * i }
        # keys =

        @processes_by_name.values.each_with_object({}) { |p, m| m[p.name] = p.dynos }
      end

      def fetch_dyno_counts
        if @client
          @dyno_counts = @client.formation.list(name)
            .select { |item| @processes_by_name.key?(item['type']) }
            .group_by { |item| item['type'] }
            .each_with_object({}) do |(key, items), memo|
              memo[key] = items.map { |item| item['quantity'] }.reduce(0, &:+)
            end
        end
        @dyno_counts
      rescue StandardError => e
        ::Sidekiq::HerokuAutoscale.exception_handler.call(e)
        @dyno_counts
      end

      def set_dyno_count!(process_name, count)
        if @client
          @client.formation.update(name, process_name, { quantity: count })
          @dyno_counts[process_name] = count
          set_history
          yield if block_given?
        end
        count
      rescue StandardError => e
        ::Sidekiq::HerokuAutoscale.exception_handler.call(e)
      end

      def set_history
        return unless @dyno_counts.present?
        hour = 60 * 60
        now = Time.now.utc.to_f
        event_time = (now / @throttle).floor * @throttle
        hour_time = (now / hour).floor * hour
        ::Sidekiq.redis do |c|
          c.multi do |t|
            key = "#{ cache_key }:#{ hour_time }"
            t.hset(key, event_time, ::Sidekiq.dump_json(@dyno_counts))
            t.expire(key, hour * 3)
          end
        end
      end

    private

      def build_processes(processes)
        processes.each_pair do |process_name, opts|
          process = Process.new(
            app: self,
            name: process_name,
            **opts.slice(:system, :scale, :quiet_buffer)
          )
          @processes_by_name[process_name.to_s] = process

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

      def cache_key
        [self.class.name.downcase, name].join(':')
      end
    end

  end
end