module Sidekiq
  module HerokuAutoscale

    class Throttle
      def initialize(before_update: 0, after_update: 0, upscale_only: false)
        @before_update = before_update
        @after_update = after_update
        @upscale_only = upscale_only
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
              @requests.reject! { |k, v| v[:manager].upscale!(v[:request_at]) }
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