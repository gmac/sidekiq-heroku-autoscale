require "heroku_autoscale/client"
require "heroku_autoscale/server"
require "heroku_autoscale/dyno_manager"

module Sidekiq
  module HerokuAutoscale

    def self.install(options)
      options = options.with_indifferent_access
      managers_by_queue_name = options[:processes].each_with_object({}) do |(name, opts), memo|
        manager = DynoManager.new(process_name: name, **opts)
        manager.queue_system.watch_queues.each do |queue_name|
          # a queue should only be managed by a single process
          # therefore, error over duplicate keys or when "*" isn't exclusive
          if memo.key?(queue_name) || memo.key?('*') || (queue_name == '*' && memo.keys.any?)
            raise ArgumentError, 'queues must be exclusive to a single process'
          end
          memo[queue_name] = manager
        end
      end

      if Sidekiq.server?
        # configure sidekiq queue server
        Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add(Server, managers_by_queue_name, 60) # 60 second timeout
          end
        end
      else
        # configure sidekiq app client
        Sidekiq.configure_client do |config|
          config.client_middleware do |chain|
            chain.add(Client, managers_by_queue_name)
          end
        end
      end
    end

  end
end