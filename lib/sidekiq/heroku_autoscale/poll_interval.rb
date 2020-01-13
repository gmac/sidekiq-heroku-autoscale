module Sidekiq
  module HerokuAutoscale

    class PollInterval
      def initialize(method_name, before_update: 0, after_update: 0)
        @method_name = method_name
        @before_update = before_update
        @after_update = after_update
        @requests = {}
      end

      def update(process)
        return unless process

        process.active_at = Time.now.utc
        @requests[process.name] ||= process

        @thread ||= Thread.new do
          begin
            while @requests.size > 0
              sleep(@before_update) if @before_update > 0
              @requests.reject! { |n, p| p.send(@method_name) }
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