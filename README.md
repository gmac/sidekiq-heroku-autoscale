# Sidekiq Heroku Autoscale plugin

This [Sidekiq](https://github.com/mperham/sidekiq) plugin allows Heroku dynos to be started, stopped, and scaled based on job workload. Why? Because running non-stop Sidekiq dynos on Heroku can rack up unnecessary costs for apps with modest background processing needs.

This is a self-acknowledged rewrite of the [autoscaler](https://github.com/JustinLove/autoscaler) project. While this plugin borrows many foundation concepts from _autoscaler_, it rewrites core operations to address several logistical concerns and enable reporting through a web UI.

Tested with Sidekiq 6, but should be compatible with other recent Sidekiq versions.

## How it works

This plugin operates by tapping into Sidekiq startup hooks and middleware.

- Whenever a server is started or a job is queued, the appropriate process manager is called on to adjust its scale. Adjustments are throttled across process instances (dynos) so that the Heroku API is only called once every N seconds – 10 by default.

- When workload demands more dynos, scale will adjust directly upward to target capacity.

- As workload diminishes, scale will adjust downward one dyno at a time. When downscaling a process, the highest numbered dyno (ex: `worker.1`, `worker.2`, etc...) will be quieted and then removed from the formation. This combines Heroku's [autoscaling logic](https://devcenter.heroku.com/articles/scaling#autoscaling-logic) with Sidekiq's [quieting strategy](https://github.com/mperham/sidekiq/wiki/Signals#tstp).

## Gem installation

```ruby
gem 'sidekiq'
gem 'sidekiq-heroku-autoscale'
```

If you're not using Rails, you'll need to require `sidekiq-heroku-autoscale` after `sidekiq`.

## Environment config

You'll need to generate a Heroku platform API token that enables your app to adjust its own dyno formation. This can be done through the Heroku CLI with:

```shell
heroku authorizations:create
```

Copy the `Token` value and add it along with your app's name as environment variables in your app:

```shell
SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN=<token>
SIDEKIQ_HEROKU_AUTOSCALE_APP=<app-name>
```

The Heroku Autoscaler plugin will automatically check for these two environment variables. You'll also find some setup suggestions in Sidekiq's [Heroku deployment](https://github.com/mperham/sidekiq/wiki/Deployment#heroku) docs. Specifically, you'll want to include the `-t 25` option in your Procfile's Sidekiq command to maximize process quietdown time:

```shell
web: bundle exec rails start
worker: bundle exec sidekiq -t 25
```

## Plugin config

Add a configuration file for the Heroku Autoscale plugin. YAML works well. A simple configuration with one `worker` process (named in your Procfile) that monitors all Sidekiq queues and starts/stops in the presence of work looks like this:

**config/sidekiq_heroku_autoscale.yml**

```yaml
app_name: test-app
processes:
  worker:
    system:
      watch_queues: *
      include_retrying: true
      include_scheduled: false
    scale:
      mode: binary
      max_dynos: 1
```

Then, add an initializer to hand your configuration off to the plugin:

**config/initializers/sidekiq.rb**

```ruby
config = YAML.load_file('<path/to/config.yml>')
Sidekiq::HerokuAutoscale.init(config)
```

A more advanced configuration with multiple process types that watch specific queues would look like this – where `first` and `second` are two Heroku process types:

```yaml
api_token: <optional - for dynamic insertion only!>
app_name: test-app
throttle: 20
history: 7200
processes:
  first:
    system:
      watch_queues:
        - default
        - low
      include_retrying: false
      include_scheduled: false
    scale:
      mode: binary
      max_dynos: 2
    quiet_buffer: 15

  second:
    system:
      watch_queues:
        - high
      include_retrying: false
      include_scheduled: false
    scale:
      mode: linear
      max_dynos: 5
      workers_per_dyno: 20
      min_factor: 1
```

**Config Options**

- `api_token:` optional, same as `SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN`. Always prefer the ENV variable, or dynamically insert this.
- `app_name:` optional, same as `SIDEKIQ_HEROKU_AUTOSCALE_APP`.
- `throttle:` number of seconds to throttle between scale adjustments. The default is 10, so the Heroku API will only be hit once every ten seconds regardless of how many time the process is pinged during that timeframe. This value also dictates the tick frequency on the web UI history graph.
- `history:` number of seconds to track history in the web UI. The default is 3600, or 1 hour. The history graph renders ticks using the history duration divided by throttle time – so 3600 seconds of history on a 10 second throttle produce 360 data points. Therefore, it's best to keep these settings in modest proportions to one another. You'll probably be sad if you try to display days or weeks of history.
- `processes:` a list of Heroku process types named in your Procfile. For example, `worker` or `sidekiq`.
- `process.system.watch_queues:` a list of Sidekiq queues to watch for work, or `*` for all queues. Queue names must be mutually exclusive to avoid collisions. That means a queue name may only appear once across all processes, and that `*` (all) may not be combined with other queue names.
- `process.system.include_retrying:` specifies if the Sidekiq retry set should be included while assessing workload. Watching retries may cause undesirable levels of uptime.
- `process.system.include_scheduled:` specifies if the Sidekiq scheduled set should be included while assessing workload. Watching scheduled jobs may cause undesirable levels of idle uptime. Also, no new jobs will be scheduled unless Sidekiq is running.
- `process.scale.mode:` accepts "binary" (on/off) or "linear" (scaled to workload).
- `process.scale.max_dynos:` maximum allowed concurrent dynos. In binary mode, this will be the fixed operating capacity. In linear mode, this will be the maximum extent that dynos may scale up to.
- `process.scale.workers_per_dyno:` Linear mode only. This specifies the anticipated workforce per dyno to calculate scale around. This should generally align with Sidekiq's `concurrency` setting.
- `process.quiet_buffer:` number of seconds to quiet a dyno (stopping it from taking on new work) before downscaling its process. This buffer occurs _before_ reducing the number of dynos for a given process type. After downscale, you may configure an [additional quietdown threshold](https://github.com/mperham/sidekiq/wiki/Deployment#heroku). Note: during this quiet buffer your formation includes a decomissioned dyno, which is awkward – thus no other scale adjustments (up or down) are allowed until the quieted dyno has been dropped. Be accordingly judicious with this buffer.

## Web UI

The web UI is an optional extension of Sidekiq's web UI. To activate it, just require `sidekiq/heroku_autoscale/web` after the base `sidekiq/web`, and then mount `Sidekiq::Web` as normal:

```ruby
require 'sidekiq/web'
require 'sidekiq/heroku_autoscale/web'

Rails.application.routes.draw do
  mount Sidekiq::Web, at: '/sidekiq'
end
```

## Tests

Nothing fancy...

```bash
# start a redis server
redis-server test/redis_test.conf

# then run tests in another terminal window
bundle exec rake test
```

### Contributors

- Justin Love [@wondible](http://twitter.com/wondible), [https://github.com/JustinLove](https://github.com/JustinLove)
- Benjamin Kudria [https://github.com/bkudria](https://github.com/bkudria)
- claudiofullscreen [https://github.com/claudiofullscreen](https://github.com/claudiofullscreen)
- Fix Peña [https://github.com/fixr](https://github.com/fixr)
- Gabriel Givigier Guimarães [https://github.com/givigier](https://github.com/givigier)
- Matt Anderson [https://github.com/tonkapark](https://github.com/tonkapark)
- Thibaud Guillaume-Gentil [https://github.com/jilion](https://github.com/jilion)

## Licence

Sidekiq Heroku Autoscale plugin is released under the [MIT license](https://opensource.org/licenses/MIT).
