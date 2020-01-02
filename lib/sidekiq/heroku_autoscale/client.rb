module Sidekiq
  module HerokuAutoscale

    # Sidekiq client middleware
    # Performs scale-up when items are queued and there are no workers running
    class Client
      def initialize(queue_managers)
        @queue_managers = queue_managers
      end

      def call(worker_class, item, queue, _=nil)
        yield
      ensure
        ClientThrottle.instance.update(@queue_managers[queue] || @queue_managers['*'])
      end
    end

    # Throttles calls to update a dyno manager.
    # Assures that a manager will only 
    class ClientThrottle
      @mutex = Mutex.new

      def self.instance
        return @instance if @instance
        @mutex.synchronize { @instance ||= new }
        @instance
      end

      def initialize
        @scheduled = {}
      end

      # Update manager immediately when ready for an update.
      # Otherwise, schedule it to update later. 
      def update(manager)
        return unless manager
        unless manager.throttle_update!
          update_later!(manager)
        end
      end

      # Adds a manager to the scheduled set,
      # then polls managers until each runs another update.
      def update_later!(manager)
        @scheduled[manager.process_name] = manager
        @throttle ||= Thread.new do
          while @scheduled.size > 0
            @scheduled.reject! { |k, m| m.throttle_update! }
            sleep 0.5
          end
          @throttle = nil
        end
      end
    end

  end
end