require_relative 'heroku_autoscale/dyno_manager'
require_relative 'heroku_autoscale/client'
require_relative 'heroku_autoscale/server'

module Sidekiq
  module HerokuAutoscale

    def self.setup(options)
      options = options.with_indifferent_access
      queue_managers = DynoManager.build_from_config(options)

      # configure sidekiq queue server
      Sidekiq.configure_server do |config|
        config.on(:startup) do
          dyno_name = ENV['DYNO'] || ENV['DYNO_NAME']
          next unless dyno_name

          manager = queue_managers.values.detect { |m| m.process_name == dyno_name.split('.').first }
          next unless manager

          Server.throttle.update(manager)
        end

        config.server_middleware do |chain|
          chain.add(Server, queue_managers)
        end

        # for jobs that queue other jobs...
        config.client_middleware do |chain|
          chain.add(Client, queue_managers)
        end
      end

      # configure sidekiq app client
      Sidekiq.configure_client do |config|
        config.on(:startup) do
          next unless options[:sidekiq_autostart]
          queue_managers.values.each { |m| Client.throttle.update(m) }
        end

        config.client_middleware do |chain|
          chain.add(Client, queue_managers)
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