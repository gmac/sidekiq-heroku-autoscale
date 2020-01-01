module Sidekiq::HerokuAutoscale
  # Sidekiq client middleware
  # Performs scale-up when items are queued and there are no workers running
  class Client
    def initialize(dyno_manager)
      @dyno_manager = dyno_manager
    end

    def call(worker_class, item, queue, _=nil)
      result = yield

      manager = @dyno_manager.is_a?(Hash) ? @dyno_manager[queue] : @dyno_manager
      ClientThrottle.update(manager)

      result
    end
  end

  class ClientThrottle
    @mutex = Mutex.new

    def self.instance
      return @instance if @instance
      @mutex.synchronize { @instance ||= new }
      @instance
    end

    def self.update(dyno_manager)
      return unless dyno_manager
      instance.run_update(dyno_manager)
    end

    def initialize
    end

    def run_update(dyno_manager)
      dyno_manager.update!
    end
  end
end