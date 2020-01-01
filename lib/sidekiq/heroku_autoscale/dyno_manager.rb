require 'platform-api'
require 'autoscaler/counter_cache_memory'

module Sidekiq::HerokuAutoscale
  class DynoManager

    attr_reader :client, :app_name, :process_name, :last_update
    attr_reader :queue_system, :scale_strategy

    attr_writer :exception_handler

    # @param [String] process_name process process_name this scaler controls
    # @param [String] token Heroku OAuth access token
    # @param [String] app_name Heroku app_name name
    def initialize(
        platform_api_token: ENV['SIDEKIQ_HEROKU_AUTOSCALE_ACCESS_TOKEN'],
        app_name: ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP'],
        process_name: 'worker',
        queue_system: {},
        scale_strategy: {}
      )

      @client = PlatformAPI.connect_oauth(token)
      @app_name = app_name
      @process_name = process_name
      @queue_system = QueueSystem.new(queue_system)
      @scale_strategy = ScaleStrategy.new(scale_strategy)
    end

    def update!
      @last_update = Time.current
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
