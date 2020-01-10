require 'sidekiq/heroku_autoscale/client'
require 'sidekiq/heroku_autoscale/heroku_app'
require 'sidekiq/heroku_autoscale/poll_interval'
require 'sidekiq/heroku_autoscale/process_manager'
require 'sidekiq/heroku_autoscale/queue_system'
require 'sidekiq/heroku_autoscale/scale_strategy'
require 'sidekiq/heroku_autoscale/server'

module Sidekiq
  module HerokuAutoscale

    DEFAULTS = {
      app: nil
    }

    class << self
      def app
        @app
      end

      def init(options)
        options = options.transform_keys(&:to_sym)
        @app = HerokuApp.new(options)

        # configure sidekiq queue server
        Sidekiq.configure_server do |config|
          config.on(:startup) do
            puts 'server startup'
            dyno_name = ENV['DYNO']
            next unless dyno_name

            process = @app.process_by_name(dyno_name.split('.').first)
            next unless process

            Server.monitor.update(process)
          end

          config.server_middleware do |chain|
            chain.add(Server, @app)
          end

          # for jobs that queue other jobs...
          config.client_middleware do |chain|
            chain.add(Client, @app)
          end
        end

        # configure sidekiq app client
        Sidekiq.configure_client do |config|
          config.client_middleware do |chain|
            chain.add(Client, @app)
          end
        end

        @app
      end
    end

    attr_writer :logger, :exception_handler

    def logger
      @logger ||= Sidekiq.logger
    end

    def exception_handler
      @exception_handler ||= lambda { |ex|
        p ex
        puts ex.backtrace
      }
    end

  end
end