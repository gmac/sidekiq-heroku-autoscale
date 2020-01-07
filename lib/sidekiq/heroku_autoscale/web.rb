require_relative 'web_extension'
require_relative 'dyno_manager'

if defined?(Sidekiq::Web)
  Sidekiq::Web.register(Sidekiq::HerokuAutoscale::WebExtension)
  Sidekiq::Web.tabs["Autoscale"] = "autoscale"
end