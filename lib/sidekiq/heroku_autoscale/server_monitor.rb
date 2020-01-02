module Sidekiq
  module HerokuAutoscale

    class ServerMonitor
      @mutex = Mutex.new

      def self.instance
        return @instance if @instance
        @mutex.synchronize { @instance ||= new }
        @instance
      end

      def self.update(dyno_manager)
        return unless dyno_manager
        instance.add_manager(dyno_manager)
      end
    end
    
  end
end