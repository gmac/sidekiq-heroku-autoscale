require 'rack/file'

module Sidekiq
  module HerokuAutoscale
    module WebExtension

      VIEW_PATH = File.join(File.expand_path('..', __FILE__), 'views')

      def self.registered(app)
        app.get '/dynos' do
          @processes = {
            default: 0,
            low: 1
          }
          render(:erb, File.read(File.join(VIEW_PATH, 'index.erb')))
        end

        app.get '/dynos/dashboard.js' do
          headers = {
            'Content-Type' => 'application/javascript',
            'Cache-Control' => 'public, max-age=86400'
          }

          [200, headers, [File.read(File.join(VIEW_PATH, 'dashboard.js'))]]
        end

        app.get '/dynos/stats' do
          sidekiq_stats = ::Sidekiq::Stats.new
          json(
            dynos: {
              worker: rand(0..3),
              sidekiq: rand(0..3),
            },
            sidekiq: {
              processed: sidekiq_stats.processed,
              failed: sidekiq_stats.failed,
              busy: sidekiq_stats.workers_size,
              processes: sidekiq_stats.processes_size,
              enqueued: sidekiq_stats.enqueued,
              scheduled: sidekiq_stats.scheduled_size,
              retries: sidekiq_stats.retry_size,
              dead: sidekiq_stats.dead_size,
              default_latency: sidekiq_stats.default_queue_latency,
            },
            server_utc_time: server_utc_time
          )
        end
      end

    end
  end
end