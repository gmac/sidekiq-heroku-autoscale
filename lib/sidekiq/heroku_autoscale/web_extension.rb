module Sidekiq
  module HerokuAutoscale
    module WebExtension

      VIEW_PATH = File.join(File.expand_path('..', __FILE__), 'views')

      def self.registered(app)
        app.get '/autoscale' do
          # @cron_jobs = Sidekiq::HerokuAutoscale::Job.all
          render(:erb, File.read(File.join(VIEW_PATH, 'index.erb')))
        end
      end

    end
  end
end