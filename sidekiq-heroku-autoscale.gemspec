# -*- encoding: utf-8 -*-
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
$:.push(lib)


Gem::Specification.new do |s|
  s.name        = 'sidekiq-heroku-autoscale'.freeze
  s.version     = '0.0.0'

  s.required_ruby_version = '~> 2.5'
  s.require_paths         = ['lib']
  s.files                 = Dir['README.md', 'lib/**/*']

  s.authors     = ['Greg MacWilliam', 'Justin Love']
  s.summary     = 'Start/stop Sidekiq workers on Heroku'
  s.description = 'Currently provides a Sidekiq middleware that does 0/1 scaling of Heroku processes'
  s.homepage    = 'https://github.com/gmac/sidekiq-heroku-autoscale'
  s.licenses    = ['MIT']

  s.add_dependency 'sidekiq', '>= 5.0'
  s.add_dependency 'platform-api', '~> 2.0'
end
