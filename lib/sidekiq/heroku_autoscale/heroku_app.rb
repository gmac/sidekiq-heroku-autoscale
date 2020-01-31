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
        @history = config[:history] || 60 * 60 # 1 hour
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
              raise ArgumentError, 'watched queues must be exclusive to a single Heroku process type'
            end
            @processes_by_queue[queue_name] = process
          end
        end
      end

      # checks if there's a live Heroku client setup
      def live?
        !!@client
      end

      # pings all processes in the application
      # useful for requesting live updates
      def ping!
        processes.each(&:ping!)
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
        histories = history_stats
        processes.each_with_object({}) do |process, memo|
          memo[process.name] = {
            dynos: process.dynos,
            status: process.status,
            updated: process.updated_at.to_s,
            history: histories[process.name],
          }
        end
      end

      def history_stats(now=Time.now.utc)
        # calculate a series time to anchor graph ticks on
        # the series snaps to thresholds of N (throttle duration)
        series_time = (now.to_f / @throttle).floor * @throttle
        num_ticks = (@history / @throttle).floor
        first_tick = series_time - @throttle * num_ticks

        # all ticks is a hash of timestamp keys to plot
        all_ticks = Array.new(num_ticks)
          .each_with_index.map { |v, i| (first_tick + @throttle * i).to_s }
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

        history_by_process = {}
        history_pages.each_slice(2).each_with_index do |(a, b), i|
          process = processes[i]

          # flatten all history pages into a single collection
          ticks = all_ticks
            .merge(a.merge!(b))
            .map { |k, v| [k.to_i, v ? v.to_i : nil] }
            .sort_by { |tick| tick[0] }

          # separate the older stats from the current history timeframe
          past_ticks, present_ticks = ticks.partition { |tick| tick[0] < first_tick }

          # select a running value starting point
          # run from the end of past history, or beginning of present history, or current dynos
          value = past_ticks.last || present_ticks.detect { |tick| !!tick[1] }
          value = value ? value[1] : process.dynos

          # assign a running value across all ticks
          present_ticks.each do |tick|
            tick[1] ||= value
            value = tick[1]
          end

          history_by_process[process.name] = present_ticks
        end

        history_by_process
      end
    end

  end
end