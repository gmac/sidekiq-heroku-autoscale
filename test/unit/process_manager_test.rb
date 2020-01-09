require 'test_helper'

describe 'Sidekiq::HerokuAutoscale::ProcessManager' do
  ENV_CONFIG = { api_token: 'b33skn33s', app_name: 'test-this' }

  before do
    Sidekiq.redis {|c| c.flushdb }
    @subject = ::Sidekiq::HerokuAutoscale::ProcessManager.new(ENV_CONFIG)
    @subject2 = ::Sidekiq::HerokuAutoscale::ProcessManager.new(ENV_CONFIG)
  end

  describe 'throttled?' do
    before do
      @subject.throttle = 10
    end

    it 'returns false when last update is blank' do
      @subject.last_update = nil
      assert_not @subject.throttled?
    end

    it 'returns false when last update falls outside the throttle' do
      @subject.last_update = Time.now.utc - 11
      assert_not @subject.throttled?
    end

    it 'returns true when last update falls within the throttle' do
      @subject.last_update = Time.now.utc - 9
      assert @subject.throttled?
    end
  end

  describe 'updated_since?' do
    it 'returns false when inquiry is blank' do
      assert_not @subject.updated_since?(nil)
    end

    it 'returns false when last update is blank' do
      @subject.last_update = nil
      assert_not @subject.updated_since?(Time.now.utc - 1)
    end

    it 'returns false when last update is before inquiry' do
      @subject.last_update = Time.now.utc - 10
      assert_not @subject.updated_since?(@subject.last_update + 1)
    end

    it 'returns true when last update is after inquiry' do
      @subject.last_update = Time.now.utc - 10
      assert @subject.updated_since?(@subject.last_update - 1)
    end
  end

  describe 'touch' do
    it 'sets updated time and caches to redis' do
      timestamp = Time.now.utc - 5
      @subject.touch(timestamp)
      assert_equal_times timestamp, @subject.last_update
      assert_equal_times timestamp, Time.parse(::Sidekiq.redis { |c| c.get(@subject.send(:cache_key, :touch)) }).utc
    end
  end

  describe 'sync_touch' do
    it 'does not sync from an empty cache' do
      @subject.last_update = nil
      assert_not @subject.sync_touch
      assert @subject.last_update.nil?
    end

    it 'does not sync a cached value older than local' do
      timestamp = Time.now.utc
      @subject2.touch(timestamp - 1)
      @subject.last_update = timestamp
      assert_not @subject.sync_touch
      assert_equal_times timestamp, @subject.last_update
    end

    it 'syncs a cached value newer than local' do
      timestamp = Time.now.utc
      @subject2.touch(timestamp)
      @subject.last_update = timestamp - 1
      assert @subject.sync_touch
      assert_equal_times timestamp, @subject.last_update
    end

    it 'syncs any cached value when locally unset' do
      timestamp = Time.now.utc
      @subject2.touch(timestamp)
      @subject.last_update = nil
      assert @subject.sync_touch
      assert_equal_times timestamp, @subject.last_update
    end
  end

  describe 'throttled?' do
    it 'checks if last update exceeds the throttle' do
      @subject.throttle = 10

      @subject.last_update = Time.now.utc - 9
      assert @subject.throttled?

      @subject.last_update = Time.now.utc - 11
      assert_not @subject.throttled?
    end
  end

  describe 'updated_since?' do
    it 'ignores empty probes' do
      assert_not @subject.updated_since?(nil)
    end

    it 'checks if last update is newer than probe time' do
      @subject.last_update = Time.now.utc - 10

      assert @subject.updated_since?(@subject.last_update - 1)
      assert_not @subject.updated_since?(@subject.last_update + 1)
    end
  end

  describe 'fulfills_quietdown?' do
    it 'returns false without a quietdown time' do
      @subject.quieted_at = nil
      assert_not @subject.fulfills_quietdown?
    end

    it 'checks if last quietdown exceeds the buffer' do
      @subject.quiet_buffer = 10

      @subject.quieted_at = Time.now.utc - 9
      assert_not @subject.fulfills_quietdown?

      @subject.quieted_at = Time.now.utc - 11
      assert @subject.fulfills_quietdown?
    end
  end

  describe 'fulfills_uptime?' do
    it 'returns false without a startup time' do
      @subject.startup_at = nil
      assert_not @subject.fulfills_uptime?
    end

    it 'checks if startup time fulfills the uptime requirement' do
      @subject.minimum_uptime = 10

      @subject.startup_at = Time.now.utc - 9
      assert_not @subject.fulfills_uptime?

      @subject.startup_at = Time.now.utc - 11
      assert @subject.fulfills_uptime?
    end
  end

  describe 'quietdown' do
    it 'assigns a downscale target' do
      @subject.quietdown(1)
      assert_equal 1, @subject.quieted_to
      assert @subject.quieted_at
      assert @subject.startup_at
    end

    it 'caches quietdown configuration' do
      @subject.quietdown(1)
      cached_value = ::Sidekiq.redis { |c| c.get(@subject.send(:cache_key, :quietdown)) }
      assert_equal [1, @subject.quieted_at.to_s], JSON.parse(cached_value)
    end

    it 'enables quietdown buffer after quieting workers' do
      @subject.queue_system.stub(:quietdown!, true) do
        @subject.quietdown(0)
        assert_not @subject.fulfills_quietdown?
      end
    end

    it 'skips quietdown buffer when there was nothing to quiet' do
      @subject.queue_system.stub(:quietdown!, false) do
        @subject.quietdown(0)
        assert @subject.fulfills_quietdown?
      end
    end

    it 'does not scale below zero' do
      @subject.quietdown(-1)
      assert_equal 0, @subject.quieted_to
    end
  end

  describe 'quieting?' do
    it 'returns true while quietdown configuration is present' do
      assert_not @subject.quieting?
      @subject.quietdown(1)
      assert @subject.quieting?
    end
  end

  describe 'stop_quietdown' do
    it 'clears quietdown configuration' do
      @subject.quietdown(1)
      assert @subject.quieted_to
      assert @subject.quieted_at

      @subject.stop_quietdown
      assert_not @subject.quieted_to
      assert_not @subject.quieted_at
      assert_not ::Sidekiq.redis { |c| c.exists(@subject.send(:cache_key, :quietdown)) }
    end
  end

  describe 'sync_quietdown' do
    it 'syncs configuration between instances' do
      @subject.quietdown(1)
      assert @subject.quieting?
      assert_not @subject2.quieting?

      @subject2.sync_quietdown
      assert @subject2.quieting?
      assert_equal @subject.quieted_to, @subject2.quieted_to
      assert_equal_times @subject.quieted_at, @subject2.quieted_at
    end
  end

  describe 'wait_for_update!' do
    it 'returns true when updated since the probe' do
      @subject.last_update = Time.now.utc - 10
      assert @subject.wait_for_update!(@subject.last_update - 1)
    end

    it 'returns false when throttled' do
      @subject.throttle = 10
      @subject.last_update = Time.now.utc - 9
      assert_not @subject.wait_for_update!(@subject.last_update + 1)
    end

    it 'returns false when a syncronized update is throttled' do
      @subject.throttle = 10
      @subject.last_update = Time.now.utc - 15
      @subject2.touch(Time.now.utc - 9)
      assert_not @subject.wait_for_update!(@subject.last_update + 1)
      assert_equal_times @subject.last_update, @subject2.last_update
    end

    it 'returns true when updated' do
      mock = MiniTest::Mock.new.expect(:call, 0)
      @subject.stub(:update!, mock) do
        @subject.throttle = 10
        @subject.last_update = Time.now.utc - 11
        assert @subject.wait_for_update!(@subject.last_update + 1)
      end
      mock.verify
    end
  end

  describe 'wait_for_shutdown!' do
    it 'returns false when throttled' do
      @subject.throttle = 10
      @subject.last_update = Time.now.utc - 9
      assert_not @subject.wait_for_shutdown!
    end

    it 'returns false when a syncronized update is throttled' do
      @subject.throttle = 10
      @subject.last_update = Time.now.utc - 15
      @subject2.touch(Time.now.utc - 9)
      assert_not @subject.wait_for_shutdown!
      assert_equal_times @subject.last_update, @subject2.last_update
    end

    it 'returns false when update returns dynos' do
      mock = MiniTest::Mock.new.expect(:call, 1)
      @subject.stub(:update!, mock) do
        @subject.throttle = 10
        @subject.last_update = Time.now.utc - 11
        assert_not @subject.wait_for_shutdown!
      end
      mock.verify
    end

    it 'returns false when update returns no dynos, but uptime has not been met' do
      mock = MiniTest::Mock.new.expect(:call, 0)
      @subject.stub(:update!, mock) do
        @subject.throttle = 10
        @subject.last_update = Time.now.utc - 11
        @subject.minimum_uptime = 10
        @subject.startup_at = Time.now.utc - 9
        assert_not @subject.wait_for_shutdown!
      end
      mock.verify
    end

    it 'returns true when update returns no dynos and uptime has been met' do
      mock = MiniTest::Mock.new.expect(:call, 0)
      @subject.stub(:update!, mock) do
        @subject.throttle = 10
        @subject.last_update = Time.now.utc - 11
        @subject.minimum_uptime = 10
        @subject.startup_at = Time.now.utc - 11
        assert @subject.wait_for_shutdown!
      end
      mock.verify
    end
  end

  describe 'update!' do
    before do
      stub_heroku_api(@subject)
    end

    it 'sets startup time when unset with workers' do
      @subject.startup_at = nil
      assert_not @subject.startup_at

      @subject.update!(0, 0)
      assert_not @subject.startup_at

      @subject.update!(1, 1)
      assert @subject.startup_at
    end

    it 'does not modify an existing startup time' do
      timestamp = Time.now.utc - 10
      @subject.startup_at = timestamp
      @subject.update!(1, 1)
      assert_equal_times timestamp, @subject.startup_at
    end

    it 'returns current dynos while idle' do
      assert_equal 2, @subject.update!(2, 2)
    end

    it 'returns target dynos when upscaling' do
      assert_equal 2, @subject.update!(1, 2)
    end

    it 'sets unset startup time when upscaling' do
      @subject.startup_at = nil
      @subject.update!(1, 2)
      assert @subject.startup_at
    end

    it 'does not modify an existing startup time when upscaling' do
      timestamp = Time.now.utc - 10
      @subject.startup_at = timestamp
      @subject.update!(1, 2)
      assert_equal_times timestamp, @subject.startup_at
    end
  end

  def stub_heroku_api(subject, dynos=0)
    subject.instance_variable_set(:@dyno_count, dynos)
    def subject.get_dyno_count; @dyno_count; end
    def subject.set_dyno_count(n); nil; end
  end
end