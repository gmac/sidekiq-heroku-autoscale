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
        return unless process

        if ::Sidekiq.server?
          process.monitor!
        else
          process.wake!
        end
      end
    end

  end
end