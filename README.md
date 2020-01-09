# sidekiq-heroku-autoscale

[Sidekiq](https://github.com/mperham/sidekiq) performs background jobs.  While its threading model allows it to scale easier than worker-pre-process background systems, people running test or lightly loaded systems on [Heroku](http://www.heroku.com/) still want to scale down to zero to avoid racking up charges.

## Installation

```ruby
gem sidekiq-heroku-autoscale
```

## Getting Started

This gem uses the [Heroku Platform-Api](https://github.com/heroku/platform-api) gem, which requires an OAuth token from Heroku.  It will also need the heroku app name.  By default, these are specified through environment variables.  You can also pass them to `HerokuPlatformScaler` explicitly.

    AUTOSCALER_HEROKU_ACCESS_TOKEN=.....
    AUTOSCALER_HEROKU_APP=....

```ruby
# initializers/sidekiq.rb
config_file = "config/sidekiq_heroku_autoscale.yml"

if File.exist?(config_file)
  Sidekiq::HerokuAutoscale.setup(YAML.load_file(config_file))
end
```

## Tests

```bash
# Start a redis server
redis-server test/redis_test.conf

# Then in another terminal window,
bundle exec rake test
```

### Contributors

- Benjamin Kudria [https://github.com/bkudria](https://github.com/bkudria)
- claudiofullscreen [https://github.com/claudiofullscreen](https://github.com/claudiofullscreen)
- Fix Peña [https://github.com/fixr](https://github.com/fixr)
- Gabriel Givigier Guimarães [https://github.com/givigier](https://github.com/givigier)
- Justin Love [@wondible](http://twitter.com/wondible), [https://github.com/JustinLove](https://github.com/JustinLove)
- Matt Anderson [https://github.com/tonkapark](https://github.com/tonkapark)
- Thibaud Guillaume-Gentil [https://github.com/jilion](https://github.com/jilion)

## Licence

Released under the [MIT license](http://www.opensource.org/licenses/mit-license.php).
