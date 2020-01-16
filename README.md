# sidekiq-heroku-autoscale

This [Sidekiq](https://github.com/mperham/sidekiq) plugin allows Heroku dynos to be started, stopped, and scaled based on job workload. Why? Because running non-stop Sidekiq dynos on Heroku may rack up unnecessary costs for apps with modest needs.

This is a self-acknowledged rewrite of the [autoscaler](https://github.com/JustinLove/autoscaler) project. While this tool borrows a significant foundation from autoscaler, it takes a new approach on many of the core operations surrounding scale transitions. persistence and durability. It also maintains a cache of data that supports a monitoring UI.

## How it works

First, nomenclature:

- Process [Type] is the _definition_ of a process, ie: a line in your Procfile... "worker: sidekiq -T 25"
- Dyno is an _instance_ of a process type.

This plugin works by tapping into Sidekiq middleware and startup hooks.

- Whenever a job is queued or a server is started, the appropraite process manager is called on to adjust its scale. Adjustments are throttled so that the Heroku API is only called once every 10 seconds (customizable).

- When workload demands more dynos than are currently running, scale will be immedaitely adjusted to meet the need.

- As workload diminishes, scale will slowly be adjusted downward one dyno at a time. When downscaling, the highest-numbered dyno (ex `worker.2` over `worker.1`) will be quieted and then removed from the pool. This slow backoff moderates wild fluctuations in queue size.



## Gem installation

```ruby
gem sidekiq-heroku-autoscale
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

The Heroku Autoscaler plugin will automatically check for these two environment variables.

## Plugin config

Next, setup a configuration file for the Heroku Autoscale gem. YAML works well. A simple configuration with one `worker` process type monitoring all Sidekiq queues that simply starts/stops in the presence of jobs looks like this:

**config/sidekiq_heroku_autoscale.yml**

```yml
app_name: test-app
processes:
  worker:
    system:
      watch_queues: *
      include_retrying: true
      include_scheduled: false
    scale:
      mode: binary
      max_workers: 1
    throttle: 10
    quiet_buffer: 10
```

Then, add an initializer that hands your configuration off to the plugin:

**config/initializers/sidekiq.rb**

```ruby
config = YAML.load_file('<path/to/config.yml>')
Sidekiq::HerokuAutoscale.init(config)
```

A more advanced configuration with multiple process types that watch specific queues would look like this – where `first` and `second` are two Heroku process types:

```yml
api_token: <optional - the ENV variable is much safer!>
app_name: test-app
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
      max_workers: 2
    throttle: 10
    quiet_buffer: 10

  second:
    system:
      watch_queues:
        - high
      include_retrying: false
      include_scheduled: false
    scale:
      mode: linear
      max_workers: 5
      worker_capacity: 50
      min_factor: 1
```

**Options**
- `api_token:` prefer the ENV variable whenever possible.
- `app_name:` name of the managed Heroku app.
- `processes:` a list of Heroku process types and specific options for each. For example, `worker` or `sidekiq`.
- `process.system.watch_queues:` a list of Sidekiq queues to watch for work, or `*` for all queues. To avoid conflicts, queue names MUST be mutually exclusive. That means queue names can only be listed once across all processes, and that select queue names cannot be combined with `*`-all.
- `process.system.include_retrying:` specifies if the Sidekiq retry set should be included while assessing workload.
- `process.system.include_scheduled:` specifies if the Sidekiq scheduled set should be included while assessing workload. Watching scheduled jobs may cause undesirable levels of idle uptime. Also, no new jobs will be scheduled unless Sidekiq is running.
- `process.scale.mode:` accepts "binary" (on/off) or "linear" (scaled to workload).
- `process.scale.max_workers:` maximum allowed concurrent dynos. In binary mode, this will be the fixed operating capacity.
- `process.throttle:` number of seconds to throttle between revaluating scale. The default is 10, meaning we'll only hit the Heroku API once every ten seconds, regardless of how many jobs are queued during that time.
- `process.quiet_buffer:` number of seconds to quiet a dyno (stopping it from taking on new work) before downscaling its process. This buffer occurs _before_ reducing the number of dynos for a given process type. You should also extend the cooldown period using `sidekiq -T 25`. Note that no new upscaling will occur during a quiet buffer.

## Tests

```bash
# Start a redis server
redis-server test/redis_test.conf

# Then in another terminal window,
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

Released under the [MIT license](http://www.opensource.org/licenses/mit-license.php).
