require_relative 'poll_interval'

module Sidekiq
  module HerokuAutoscale

    # Sidekiq client middleware
    # Performs scale-up when items are queued and there are no workers running
    class Server
      @mutex = Mutex.new

      def self.monitor
        return @monitor if @monitor
        @mutex.synchronize { @monitor ||= PollInterval.new(:wait_for_shutdown!, before_update: 10) }
        @monitor
      end

      def initialize(queue_managers)
        @queue_managers = queue_managers
      end

      def call(worker_class, item, queue, _=nil)
        yield
      ensure
        self.class.monitor.update(@queue_managers[queue] || @queue_managers['*'])
      end
    end

  end
end