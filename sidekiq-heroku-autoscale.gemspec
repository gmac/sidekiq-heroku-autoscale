# -*- encoding: utf-8 -*-
$:.push File.expand_path('../lib', __FILE__)
require 'sidekiq/heroku_autoscale/version'

Gem::Specification.new do |s|
  s.name        = 'sidekiq-heroku-autoscale'.freeze
  s.version     = Sidekiq::HerokuAutoscale::VERSION

  s.required_ruby_version = '~> 2.5'
  s.require_paths         = ['lib']
  s.files                 = Dir['README.md', 'lib/**/*']

  s.authors     = ['Greg MacWilliam', 'Justin Love']
  s.summary     = 'Start, stop, and scale Sidekiq dynos on Heroku based on workload'
  s.description = s.summary
  s.homepage    = 'https://github.com/gmac/sidekiq-heroku-autoscale'
  s.licenses    = ['MIT']

  s.add_dependency 'sidekiq', '>= 5.0'
  s.add_dependency 'platform-api', '~> 2.0'
end
