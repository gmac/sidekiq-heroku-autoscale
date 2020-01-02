require "heroku_autoscale/client"
require "heroku_autoscale/dyno_manager"
require "heroku_autoscale/queue_system"
require "heroku_autoscale/scale_strategy"
require "heroku_autoscale/server"
require "heroku_autoscale/server_monitor"

module Sidekiq
  module HerokuAutoscale

    def self.setup(options)
      queue_managers = DynoManager.build_from_config(options.with_indifferent_access)

      if Sidekiq.server?
        # configure sidekiq queue server
        Sidekiq.configure_server do |config|
          config.on(:start) do
            dyno_name = ENV['DYNO'] || ENV['DYNO_NAME']
            next unless dyno_name

            manager = queue_managers.values.detect { |m| m.process_name == dyno_name.split('.').first }
            next unless manager

            ServerMonitor.update(manager)
          end

          config.server_middleware do |chain|
            chain.add(Server, queue_managers)
          end
        end
      else
        # configure sidekiq app client
        Sidekiq.configure_client do |config|
          config.client_middleware do |chain|
            chain.add(Client, queue_managers)
          end
        end
      end
    end

    def self.redis(source=nil, &block)
      source ||= ::Sidekiq.method(:redis)
      if source.respond_to?(:call) && !source.kind_of?(Redis)
        source.call(&block)
      elsif source.respond_to?(:with)
        source.with(&block)
      else
        block.call(source)
      end
    end

  end
end