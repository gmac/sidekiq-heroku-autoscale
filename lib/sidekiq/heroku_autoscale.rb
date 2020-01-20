require 'sidekiq/heroku_autoscale/heroku_app'
require 'sidekiq/heroku_autoscale/middleware'
require 'sidekiq/heroku_autoscale/poll_interval'
require 'sidekiq/heroku_autoscale/process'
require 'sidekiq/heroku_autoscale/queue_system'
require 'sidekiq/heroku_autoscale/scale_strategy'

module Sidekiq
  module HerokuAutoscale

    class << self
      def app
        @app
      end

      def init(options)
        options = options.transform_keys(&:to_sym)
        @app = HerokuApp.new(options)

        ::Sidekiq.logger.warn('Heroku platform API is not configured for Sidekiq::HerokuAutoscale') unless @app.live?

        # configure sidekiq queue server
        ::Sidekiq.configure_server do |config|
          config.on(:startup) do
            dyno_name = ENV['DYNO']
            next unless dyno_name

            process = @app.process_by_name(dyno_name.split('.').first)
            next unless process

            process.monitor!
          end

          config.server_middleware do |chain|
            chain.add(Middleware, @app)
          end

          # for jobs that queue other jobs...
          config.client_middleware do |chain|
            chain.add(Middleware, @app)
          end
        end

        # configure sidekiq app client
        ::Sidekiq.configure_client do |config|
          config.client_middleware do |chain|
            chain.add(Middleware, @app)
          end
        end

        unless ::Sidekiq.server?
          @app.processes.each(&:wake!)
        end

        @app
      end

      def exception_handler
        @exception_handler ||= lambda { |ex|
          p ex
          puts ex.backtrace
        }
      end

      attr_writer :exception_handler
    end

  end
end