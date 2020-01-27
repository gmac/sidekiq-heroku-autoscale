module Sidekiq
  module HerokuAutoscale

    class Middleware
      def initialize(app)
        @app = app
      end

      def call(worker_class, item, queue, _=nil)
        result = yield

        if process = @app.process_for_queue(queue)
          process.ping!
        end

        result
      end
    end

  end
end