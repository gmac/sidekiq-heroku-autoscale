require_relative 'throttle'

module Sidekiq
  module HerokuAutoscale

    # Sidekiq client middleware
    # Performs scale-up when items are queued and there are no workers running
    class Client
      @mutex = Mutex.new

      def self.throttle
        return @throttle if @throttle
        @mutex.synchronize { @throttle ||= Throttle.new(after_update: 1, upscale_only: true) }
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