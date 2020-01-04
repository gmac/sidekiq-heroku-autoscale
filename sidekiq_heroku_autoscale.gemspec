# -*- encoding: utf-8 -*-
$:.push File.expand_path('../lib', __FILE__)
require 'sidekiq/heroku_autoscale/version'

Gem::Specification.new do |s|
  s.authors     = ['Greg MacWilliam', 'Justin Love', 'Fix Peña']
  s.summary     = 'Start/stop Sidekiq workers on Heroku'
  s.description = 'Currently provides a Sidekiq middleware that does 0/1 scaling of Heroku processes'
  s.homepage    = 'https://github.com/gmac/sidekiq-heroku-autoscale'
  s.licenses    = ['MIT']

  s.name        = 'sidekiq_heroku_autoscale'
  s.version     = Sidekiq::HerokuAutoscale::VERSION
  s.files       = Dir['README.md', 'lib/**/*']
  s.require_paths = ['lib']
  s.required_ruby_version = '~> 2.5'

  s.add_dependency 'sidekiq', '~> 5.0'
  s.add_dependency 'platform-api', '~> 2.0'
end
