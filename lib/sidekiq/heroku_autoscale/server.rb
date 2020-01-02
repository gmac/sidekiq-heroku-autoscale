module Sidekiq
  module HerokuAutoscale

    # Sidekiq client middleware
    # Performs scale-up when items are queued and there are no workers running
    class Server
      def initialize(queue_managers)
        @queue_managers = queue_managers
      end

      def call(worker_class, item, queue, _=nil)
        yield
      ensure
        ServerMonitor.update(@queue_managers[queue] || @queue_managers['*'])
      end
    end

  end
end