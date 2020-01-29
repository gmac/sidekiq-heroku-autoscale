require 'test_helper'
require 'yaml'

describe 'HerokuApp' do
  before do
    Sidekiq.redis {|c| c.flushdb }
    ENV['SIDEKIQ_HEROKU_AUTOSCALE_API_TOKEN'] = 'humd1ng3r'
    ENV['SIDEKIQ_HEROKU_AUTOSCALE_APP'] = 'testing-app'
    @subject = ::Sidekiq::HerokuAutoscale::HerokuApp
  end

  describe 'new' do
    it 'builds app with options' do
      config = YAML.load_file("#{ FIXTURES_PATH }/config.yml")
      app = @subject.new(config)

      assert_equal %w[default low high], app.queue_names

      first = app.process_for_queue('low')
      assert_equal 'test-app', first.app_name
      assert_equal 'first', first.name
      assert_equal %w[default low], first.queue_system.watch_queues
      assert_not first.queue_system.include_retrying
      assert_not first.queue_system.include_scheduled
      assert_equal 'binary', first.scale_strategy.mode
      assert_equal 2, first.scale_strategy.max_dynos
      assert_equal 3600, first.history
      assert_equal 15, first.throttle
      assert_equal 15, first.quiet_buffer

      second = app.process_for_queue('high')
      assert_equal 'test-app', second.app_name
      assert_equal 'second', second.name
      assert_equal %w[high], second.queue_system.watch_queues
      assert_equal 'linear', second.scale_strategy.mode
      assert_equal 5, second.scale_strategy.max_dynos
      assert_equal 50, second.scale_strategy.workers_per_dyno
      assert_equal 1, second.scale_strategy.min_factor
      assert_equal 3600, second.history
      assert_equal 15, second.throttle
      assert_equal 20, second.quiet_buffer
    end

    it 'fills in name/token with environment variables' do
      app = @subject.new({
        processes: {
          first: { system: { watch_queues: %w[low] } }
        }
      })
      assert_equal 'testing-app', app.process_for_queue('low').app_name
      assert app.live?
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

  describe 'process accessors' do
    before do
      @app = @subject.new({
        processes: {
          first: { system: { watch_queues: %w[low] } },
          second: { system: { watch_queues: %w[med high] } }
        }
      })
    end

    it 'lists process names' do
      assert_equal %w[first second], @app.process_names
    end

    it 'lists queue names' do
      assert_equal %w[low med high], @app.queue_names
    end

    it 'gets processes by name' do
      assert_equal 'first', @app.process_by_name('first').name
      assert_equal 'second', @app.process_by_name('second').name
    end

    it 'gets processes by queue' do
      assert_equal 'first', @app.process_for_queue('low').name
      assert_equal 'second', @app.process_for_queue('med').name
      assert_equal 'second', @app.process_for_queue('high').name
    end
  end

  describe 'history_stats' do
    before do
      @app = @subject.new({
        history: 100,
        throttle: 10,
        processes: {
          first: { system: { watch_queues: %w[low] } },
          second: { system: { watch_queues: %w[high] } }
        }
      })
    end

    it 'generates a running history from present dynos' do
      @app.process_by_name('second').dynos = 1
      stats = @app.history_stats

      assert_equal [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], stats['first'].map { |tick| tick[1] }
      assert_equal [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], stats['second'].map { |tick| tick[1] }
    end

    it 'generates a running history from logged data points' do
      epoch = Time.now.utc
      @app.process_by_name('first').set_attributes(dynos: 1, history_at: epoch - 110)
      @app.process_by_name('first').set_attributes(dynos: 1, history_at: epoch - 80)
      @app.process_by_name('first').set_attributes(dynos: 0, history_at: epoch - 70)
      @app.process_by_name('first').set_attributes(dynos: 0, history_at: epoch - 40)
      @app.process_by_name('first').set_attributes(dynos: 1, history_at: epoch - 30)

      @app.process_by_name('second').set_attributes(dynos: 1, history_at: epoch - 110)
      @app.process_by_name('second').set_attributes(dynos: 2, history_at: epoch - 50)
      @app.process_by_name('second').set_attributes(dynos: 0, history_at: epoch - 40)

      stats = @app.history_stats(epoch)
      assert_equal [1, 1, 1, 0, 0, 0, 0, 1, 1, 1], stats['first'].map { |tick| tick[1] }
      assert_equal [1, 1, 1, 1, 1, 2, 0, 0, 0, 0], stats['second'].map { |tick| tick[1] }
    end
  end
end