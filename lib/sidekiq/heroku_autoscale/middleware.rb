module Sidekiq
  module HerokuAutoscale

    class Middleware
      def initialize(app)
        @app = app
      end

      def call(worker_class, item, queue, _=nil)
        yield
      ensure
        process = @app.process_for_queue(queue)

        if ::Sidekiq.server?
          ::Sidekiq::HerokuAutoscale::Process.server.update(process)
        else
          ::Sidekiq::HerokuAutoscale::Process.throttle.update(process)
        end
      end
    end

  end
end