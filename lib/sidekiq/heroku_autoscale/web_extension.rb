require 'rack/file'

module Sidekiq
  module HerokuAutoscale
    module WebExtension

      WEB_PATH = File.join(File.expand_path('..', __FILE__), 'web')

      JS_HEADERS = {
        'Content-Type' => 'application/javascript',
        'Cache-Control' => 'public, max-age=86400'
      }.freeze

      def self.registered(web)
        web.get '/dynos' do
          if app = ::Sidekiq::HerokuAutoscale.app
            app.ping!
            @dyno_stats = app.stats
            puts @dyno_stats
          end
          render(:erb, File.read(File.join(WEB_PATH, "#{ @dyno_stats ? 'index' : 'inactive' }.erb")))
        end

        web.get '/dynos/stats' do
          if app = ::Sidekiq::HerokuAutoscale.app
            app.ping!
          end
          json(stats: app ? app.stats : {})
        end

        web.get '/dynos/index.js' do
          [200, JS_HEADERS, [File.read(File.join(WEB_PATH, 'index.js'))]]
        end
      end

    end
  end
end