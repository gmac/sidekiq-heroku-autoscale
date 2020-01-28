require 'platform-api'

module Sidekiq
  module HerokuAutoscale

    class HerokuApp
      attr_reader :app_name, :throttle, :history

      # Builds process managers based on configuration (presumably loaded from YAML)
      def initialize(config)
        config = JSON.parse(JSON.generate(config), symbolize_names: true)

        api_token = config[:api_token] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN']
        @app_name = config[:app_name] || ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP']
        @throttle = config[:throttle] || 10
        @history = config[:history] || 60 * 60 * 3 # 3 hours
        @client = api_token ? PlatformAPI.connect_oauth(api_token) : nil

        @processes_by_name = {}
        @processes_by_queue = {}

        config[:processes].each_pair do |name, opts|
          process = Process.new(
            app_name: @app_name,
            name: name,
            client: @client,
            throttle: @throttle,
            history: @history,
            **opts.slice(:system, :scale, :quiet_buffer)
          )
          @processes_by_name[name.to_s] = process

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
        @processes ||= @processes_by_name.values
      end

      def process_names
        @process_names ||= @processes_by_name.keys
      end

      def queue_names
        @queue_names ||= @processes_by_queue.keys
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

      def dyno_history(now: Time.now.utc)
        # calculate a series time to anchor graph ticks on
        # the series snaps to thresholds of N (throttle duration)
        series_time = (now.to_f / @throttle).floor * @throttle
        num_ticks = (@history / @throttle).floor
        first_tick = series_time - @throttle * num_ticks

        # ticks is an array of timestamps to plot
        all_ticks = Array.new(num_ticks)
          .each_with_index.map { |v, i| first_tick + @throttle * i }
          .each_with_object({}) { |tick, memo| memo[tick] = nil }

        # get current and previous history collections for each process
        # history pages snap to thresholds of M (history duration)
        current_page = (now.to_f / @history).floor * @history
        previous_page = current_page - @history
        history_pages = ::Sidekiq.redis do |c|
          c.pipelined do
            processes.each do |process|
              c.hgetall("#{ process.cache_key }:#{ previous_page }")
              c.hgetall("#{ process.cache_key }:#{ current_page }")
            end
          end
        end

        # flatten all history pages into a single hash
        history_by_name = {}
        history_pages.each_slice(2).each_with_index do |(a, b), i|
          process = processes[i]

          ticks = a.merge!(b)
            .transform_keys! { |k| k.to_i }
            .reject { |k, v| k < first_tick }
            #.transform_values! { |v| v.to_i }

          ticks = all_ticks
            .merge(ticks)
            .sort_by { |k| k }

          value = ticks.detect { |(k, v)| !v.nil? }
          value = value ? value.last : process.dynos
          ticks.each do |tick|
            tick[1] ||= value
            value = tick[1]
          end

          history_by_name[process.name] = ticks
        end

        puts history_by_name
      end
    end

  end
end