module Sidekiq
  module HerokuAutoscale

    # Sidekiq client middleware
    # Performs scale-up when items are queued and there are no workers running
    class Client
      ACCESSOR_MUTEX = Mutex.new
      @throttle = nil

      def self.throttle
        return @throttle if @throttle
        ACCESSOR_MUTEX.synchronize { @throttle ||= PollInterval.new(:wait_for_update!, after_update: 1) }
        @throttle
      end

      def initialize(formation)
        @formation = formation
      end

      def call(worker_class, item, queue, _=nil)
        puts '**CLIENT'
        yield
      ensure
        self.class.throttle.update(@formation.process_for_queue(queue))
      end
    end

  end
end