module Sidekiq
  module HerokuAutoscale

    class PollInterval
      def initialize(method_name, before_update: 0, after_update: 0)
        @method_name = method_name
        @before_update = before_update
        @after_update = after_update
        @requests = {}
      end

      def update(manager)
        return unless manager

        @requests[manager.process_name] ||= { manager: manager }
        @requests[manager.process_name][:request_at] = Time.now.utc

        @thread ||= Thread.new do
          begin
            while @requests.size > 0
              sleep(@before_update) if @before_update > 0
              @requests.reject! { |k, v| v[:manager].send(@method_name, v[:request_at]) }
              sleep(@after_update) if @after_update > 0
            end
          ensure
            @thread = nil
          end
        end
      end
    end

  end
end