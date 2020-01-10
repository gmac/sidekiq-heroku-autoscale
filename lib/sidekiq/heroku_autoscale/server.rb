module Sidekiq
  module HerokuAutoscale

    # Sidekiq client middleware
    # Performs scale-up when items are queued and there are no workers running
    class Server
      ACCESSOR_MUTEX = Mutex.new
      @monitor = nil

      def self.monitor
        return @monitor if @monitor
        ACCESSOR_MUTEX.synchronize { @monitor ||= PollInterval.new(:wait_for_shutdown!, before_update: 10) }
        @monitor
      end

      def initialize(formation)
        @formation = formation
      end

      def call(worker_class, item, queue, _=nil)
        puts '**SERVER'
        yield
      ensure
        self.class.monitor.update(@formation.process_for_queue(queue))
      end
    end

  end
end