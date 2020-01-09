module Sidekiq
  module HerokuAutoscale

    # Sidekiq client middleware
    # Performs scale-up when items are queued and there are no workers running
    class Client
      @mutex = Mutex.new
      @throttle = nil

      def self.throttle
        return @throttle if @throttle
        @mutex.synchronize { @throttle ||= PollInterval.new(:wait_for_update!, after_update: 1) }
        @throttle
      end

      def initialize(formation)
        @formation = formation
      end

      def call(worker_class, item, queue, _=nil)
        yield
      ensure
        self.class.throttle.update(@formation.process_for_queue(queue))
      end
    end

  end
end