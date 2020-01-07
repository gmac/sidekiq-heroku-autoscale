require 'test_helper'
require 'yaml'

describe 'DynoManager.build_from_config' do
  before do
    ENV['SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN'] = 'n4d4'
    ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP'] = 'testing'
    @subject = ::Sidekiq::HerokuAutoscale::DynoManager
  end

  it 'builds managers with options' do
    config = YAML.load_file(File.expand_path("../../fixtures/config.yml", __FILE__))
    managers_by_queue = @subject.build_from_config(config)

    assert_equal %w[default low high], managers_by_queue.keys

    first = managers_by_queue['low']
    assert_equal 'test-app', first.app_name
    assert_equal 'first', first.process_name
    assert_equal %w[default low], first.queue_system.watch_queues
    assert_not first.queue_system.include_retrying
    assert_not first.queue_system.include_scheduled
    assert_equal 'binary', first.scale_strategy.mode
    assert_equal 2, first.scale_strategy.max_workers
    assert_equal 15, first.throttle
    assert_equal 15, first.quiet_buffer
    assert_equal 15, first.minimum_uptime

    second = managers_by_queue['high']
    assert_equal 'test-app', second.app_name
    assert_equal 'second', second.process_name
    assert_equal %w[high], second.queue_system.watch_queues
    assert_equal 'linear', second.scale_strategy.mode
    assert_equal 5, second.scale_strategy.max_workers
    assert_equal 50, second.scale_strategy.worker_capacity
    assert_equal 1, second.scale_strategy.min_factor
    assert_equal 20, second.throttle
    assert_equal 20, second.quiet_buffer
    assert_equal 20, second.minimum_uptime
  end

  it 'fills in name/token with environment variables' do
    managers_by_queue = @subject.build_from_config({
      processes: {
        first: { system: { watch_queues: %w[low] } }
      }
    })
    assert_equal ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP'], managers_by_queue['low'].app_name
  end

  it 'errors for queues shared across process types' do
    assert_raises_message(ArgumentError, /must be exclusive/) do
      @subject.build_from_config({
        processes: {
          first: { system: { watch_queues: %w[low medium] } },
          second: { system: { watch_queues: %w[medium high] } }
        }
      })
    end
  end

  it 'errors when all-queues is not exclusive' do
    assert_raises_message(ArgumentError, /must be exclusive/) do
      @subject.build_from_config({
        processes: {
          first: { system: { watch_queues: '*' } },
          second: { system: { watch_queues: %w[high] } }
        }
      })
    end
  end
end