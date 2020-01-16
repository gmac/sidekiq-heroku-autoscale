module Sidekiq
  module HerokuAutoscale

    class Middleware
      def initialize(app)
        @app = app
      end

      def call(worker_class, item, queue, _=nil)
        result = yield

        puts "Middleware! #{ !!::Sidekiq.server? }"
        puts ::Sidekiq::Stats.new.queues

        if process = @app.process_for_queue(queue)
          if ::Sidekiq.server?
            process.monitor!
          else
            process.wake!
          end
        end

        result
      end
    end

  end
end