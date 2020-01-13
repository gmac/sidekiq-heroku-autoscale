require 'test_helper'
require 'yaml'

describe 'HerokuApp' do
  before do
    ENV['SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN'] = 'humd1ng3r'
    ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP'] = 'testing-app'
    @subject = ::Sidekiq::HerokuAutoscale::HerokuApp
  end

  it 'builds app with options' do
    config = YAML.load_file(File.expand_path("../../fixtures/config.yml", __FILE__))
    app = @subject.new(config)

    assert_equal %w[default low high], app.queue_names

    first = app.process_for_queue('low')
    assert_equal 'test-app', first.app_name
    assert_equal 'first', first.name
    assert_equal %w[default low], first.queue_system.watch_queues
    assert_not first.queue_system.include_retrying
    assert_not first.queue_system.include_scheduled
    assert_equal 'binary', first.scale_strategy.mode
    assert_equal 2, first.scale_strategy.max_workers
    assert_equal 15, first.throttle
    assert_equal 15, first.quiet_buffer
    assert_equal 15, first.minimum_uptime

    second = app.process_for_queue('high')
    assert_equal 'test-app', second.app_name
    assert_equal 'second', second.name
    assert_equal %w[high], second.queue_system.watch_queues
    assert_equal 'linear', second.scale_strategy.mode
    assert_equal 5, second.scale_strategy.max_workers
    assert_equal 50, second.scale_strategy.worker_capacity
    assert_equal 1, second.scale_strategy.min_factor
    assert_equal 20, second.throttle
    assert_equal 20, second.quiet_buffer
    assert_equal 20, second.minimum_uptime
  end

  it 'provides processes by name and by queue' do
    app = @subject.new({
      processes: {
        first: { system: { watch_queues: %w[low] } },
        second: { system: { watch_queues: %w[med high] } }
      }
    })
    assert_equal [:first, :second], app.process_names
    assert_equal %w[low med high], app.queue_names
  end

  it 'fills in name/token with environment variables' do
    app = @subject.new({
      processes: {
        first: { system: { watch_queues: %w[low] } }
      }
    })
    assert_equal 'testing-app', app.process_for_queue('low').app_name
  end

  it 'errors for queues shared across process types' do
    assert_raises_message(ArgumentError, /must be exclusive/) do
      @subject.new({
        processes: {
          first: { system: { watch_queues: %w[low medium] } },
          second: { system: { watch_queues: %w[medium high] } }
        }
      })
    end
  end

  it 'errors when all-queues is not exclusive' do
    assert_raises_message(ArgumentError, /must be exclusive/) do
      @subject.new({
        processes: {
          first: { system: { watch_queues: '*' } },
          second: { system: { watch_queues: %w[high] } }
        }
      })
    end
  end
end