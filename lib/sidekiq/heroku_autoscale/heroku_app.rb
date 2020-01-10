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
        @app_name = config[:app_name] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP']
        @client = api_token ? PlatformAPI.connect_oauth(api_token) : nil

        ::Sidekiq.logger.warn('Platform API is not configured for Sidekiq::HerokuAutoscale') unless @client && @app_name

        @processes_by_name = {}
        @processes_by_queue = {}
        @dyno_counts = {}

        config[:processes].each_pair do |name, opts|
          process = ProcessManager.new(api_client: @client, app_name: @app_name, process_name: name, **opts)
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

      def recent_update_for?(process_name)
        last_update = @dyno_counts.dig(process_name, :updated)
        last_update && Time.now.utc >= last_update + throttle
      end

      def get_dyno_count(process_name)
        return get_cached_dyno_count(process_name) if recent_update_for?(process_name)
        load_cached_dyno_counts

        return get_cached_dyno_count(process_name) if recent_update_for?(process_name)
        fetch_live_dyno_counts

        get_cached_dyno_count(process_name)
      end

      def set_dyno_count(process_name, count)
        @client.formation.update(app_name, process_name, { quantity: count }) if @client.present?
        store_dyno_count(process_name, count)
      rescue StandardError => e
        ::Sidekiq::HerokuAutoscale.exception_handler.call(e)
      end

    private

      def fetch_live_dyno_counts
        if @client
          @client.formation.list(app_name)
            .select { |item| process_names.include?(item['type']) }
            .group_by { |item| item['type'] }
            .each_pair do |process_name, group|
              store_dyno_count(process_name, group.map { |item| item['quantity'] }.reduce(0, &:+))
            end
        else
          process_names.each do |process_name|
            store_dyno_count(process_name, get_cached_dyno_count(process_name))
          end
        end
      rescue StandardError => e
        ::Sidekiq::HerokuAutoscale.exception_handler.call(e)
      end

      def load_cached_dyno_counts
        pipe = ::Sidekiq.redis do |c|
          c.pipelined { process_names.each { |n| c.hgetall(process_cache_key(n)) } }
        end

        pipe.each do |item|
          next unless item['name']
          @dyno_counts[item['name']] ||= {}
          @dyno_counts[:count] = item['count'].to_i
          @dyno_counts[:updated] = Time.at(item['updated'].to_i
        end
      end

      def get_cached_dyno_count(process_name)
        @dyno_counts.dig(process_name, :count) || 0
      end

      def store_dyno_count(process_name, count)
        updated = Time.now.utc
        @dyno_counts[process_name] ||= {}
        @dyno_counts[:count] = count
        @dyno_counts[:updated] = updated
        ::Sidekiq.redis.hset(process_cache_key(process_name), 'name', process_name, 'count', count, 'updated', updated.to_i)
      end

      def process_cache_key(process_name)
        "#{ self.class.name.gsub('::', ':').downcase }:#{ app_name }:process:#{ process_name }"
      end
    end

  end
end