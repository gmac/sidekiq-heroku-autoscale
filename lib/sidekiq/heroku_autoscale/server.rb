require_relative 'throttle'

module Sidekiq
  module HerokuAutoscale

    # Sidekiq client middleware
    # Performs scale-up when items are queued and there are no workers running
    class Server
      @mutex = Mutex.new

      def self.throttle
        return @throttle if @throttle
        @mutex.synchronize { @throttle ||= Throttle.new(before_update: 10) }
        @throttle
      end

      def initialize(queue_managers)
        @queue_managers = queue_managers
      end

      def call(worker_class, item, queue, _=nil)
        yield
      ensure
        self.class.throttle.update(@queue_managers[queue] || @queue_managers['*'])
      end
    end

  end
end