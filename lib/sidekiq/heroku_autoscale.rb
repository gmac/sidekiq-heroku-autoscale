require 'sidekiq/heroku_autoscale/client'
require 'sidekiq/heroku_autoscale/formation_manager'
require 'sidekiq/heroku_autoscale/poll_interval'
require 'sidekiq/heroku_autoscale/process_manager'
require 'sidekiq/heroku_autoscale/queue_system'
require 'sidekiq/heroku_autoscale/scale_strategy'
require 'sidekiq/heroku_autoscale/server'

module Sidekiq
  module HerokuAutoscale

    class << self
      def init(options)
        options = options.transform_keys(&:to_sym)
        formation = FormationManager.build_from_config(options)

        # configure sidekiq queue server
        Sidekiq.configure_server do |config|
          config.on(:startup) do
            dyno_name = ENV['DYNO']
            next unless dyno_name

            process = formation.process_by_name(dyno_name.split('.').first)
            next unless process

            Server.monitor.update(process)
          end

          config.server_middleware do |chain|
            chain.add(Server, formation)
          end

          # for jobs that queue other jobs...
          config.client_middleware do |chain|
            chain.add(Client, formation)
          end
        end

        # configure sidekiq app client
        Sidekiq.configure_client do |config|
          config.on(:startup) do
            next unless options[:sidekiq_autostart]
            formation.values.each { |m| Client.throttle.update(m) }
          end

          config.client_middleware do |chain|
            chain.add(Client, formation)
          end
        end

        formation
      end
    end

  end
end