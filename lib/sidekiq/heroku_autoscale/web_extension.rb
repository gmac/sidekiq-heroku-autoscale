require 'rack/file'

module Sidekiq
  module HerokuAutoscale
    module WebExtension

      WEB_PATH = File.join(File.expand_path('..', __FILE__), 'web')

      JS_HEADERS = {
        'Content-Type' => 'application/javascript',
        'Cache-Control' => 'public, max-age=86400'
      }.freeze

      def self.registered(app)
        app.get '/dynos' do
          @app = ::Sidekiq::HerokuAutoscale.app
          render(:erb, File.read(File.join(WEB_PATH, 'index.erb')))
        end

        app.get '/dynos/live' do
          if @app = ::Sidekiq::HerokuAutoscale.app
            @app.processes.each(&:ping!)
            json(stats: @app.history_stats)
          else
            json(stats: {})
          end
        end

        app.get '/dynos/index.js' do
          [200, JS_HEADERS, [File.read(File.join(WEB_PATH, 'index.js'))]]
        end
      end

    end
  end
end