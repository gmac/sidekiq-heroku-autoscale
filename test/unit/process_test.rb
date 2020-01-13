require 'test_helper'

describe 'Sidekiq::HerokuAutoscale::Process' do
  ENV_CONFIG = { app_name: 'test-this' }

  before do
    Sidekiq.redis {|c| c.flushdb }
    @subject = ::Sidekiq::HerokuAutoscale::Process.new(ENV_CONFIG)
    @subject2 = ::Sidekiq::HerokuAutoscale::Process.new(ENV_CONFIG)
  end

  describe 'throttled?' do
    before do
      @subject.throttle = 10
    end

    it 'returns false when last update is blank' do
      @subject.updated_at = nil
      assert_not @subject.throttled?
    end

    it 'returns false when last update falls outside the throttle' do
      @subject.updated_at = Time.now.utc - 11
      assert_not @subject.throttled?
    end

    it 'returns true when last update falls within the throttle' do
      @subject.updated_at = Time.now.utc - 9
      assert @subject.throttled?
    end
  end

  describe 'updated_since_last_activity?' do
    it 'returns false when last activity is blank' do
      @subject.active_at = nil
      @subject.updated_at = Time.now.utc - 1
      assert_not @subject.updated_since_last_activity?
    end

    it 'returns false when last update is blank' do
      @subject.active_at = Time.now.utc - 1
      @subject.updated_at = nil
      assert_not @subject.updated_since_last_activity?
    end

    it 'returns false when last update is before inquiry' do
      @subject.active_at = Time.now.utc - 10
      @subject.updated_at = @subject.active_at - 1
      assert_not @subject.updated_since_last_activity?
    end

    it 'returns true when last update is after inquiry' do
      @subject.active_at = Time.now.utc - 10
      @subject.updated_at = @subject.active_at + 1
      assert @subject.updated_since_last_activity?
    end
  end

  describe 'quieting?' do
    it 'returns false when quieting values not set' do
      @subject.quieted_to = nil
      @subject.quieted_at = nil
      assert_not @subject.quieting?

      @subject.quieted_to = 0
      @subject.quieted_at = nil
      assert_not @subject.quieting?

      @subject.quieted_to = nil
      @subject.quieted_at = Time.now.utc
      assert_not @subject.quieting?
    end

    it 'returns true when quieting values are set' do
      @subject.quieted_to = 0
      @subject.quieted_at = Time.now.utc
      assert @subject.quieting?
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
      @subject.started_at = nil
      assert_not @subject.fulfills_uptime?
    end

    it 'checks if startup time fulfills the uptime requirement' do
      @subject.minimum_uptime = 10

      @subject.started_at = Time.now.utc - 9
      assert_not @subject.fulfills_uptime?

      @subject.started_at = Time.now.utc - 11
      assert @subject.fulfills_uptime?
    end
  end

  describe 'set_attributes' do
    it 'sets dyno count with a startup time' do
      @subject.started_at = nil
      @subject.set_attributes(dynos: 2)
      cached = Sidekiq.redis { |c| c.hgetall(@subject.cache_key) }

      assert_equal 2, @subject.dynos
      assert @subject.started_at

      assert_equal '2', cached['dynos']
      assert_equal @subject.started_at.to_i.to_s, cached['started_at']
    end

    it 'clears startup time when setting zero dynos' do
      @subject.set_attributes(dynos: 0)
      cached = Sidekiq.redis { |c| c.hgetall(@subject.cache_key) }
      assert_equal 0, @subject.dynos
      assert_not @subject.started_at

      assert_equal '0', cached['dynos']
      assert_not cached.key?('started_at')
    end

    it 'sets and clears a quieted-to count' do
      @subject.set_attributes(quieted_to: 1)
      cached = Sidekiq.redis { |c| c.hgetall(@subject.cache_key) }
      assert_equal 1, @subject.quieted_to
      assert_equal '1', cached['quieted_to']

      @subject.set_attributes(quieted_to: nil)
      cached = Sidekiq.redis { |c| c.hgetall(@subject.cache_key) }
      assert @subject.quieted_to.nil?
      assert_not cached.key?('quieted_to')
    end

    it 'sets and clears a quieted-at time' do
      @subject.set_attributes(quieted_at: Time.now.utc)
      cached = Sidekiq.redis { |c| c.hgetall(@subject.cache_key) }
      assert @subject.quieted_at
      assert_equal @subject.quieted_at.to_i.to_s, cached['quieted_at']

      @subject.set_attributes(quieted_at: nil)
      cached = Sidekiq.redis { |c| c.hgetall(@subject.cache_key) }
      assert @subject.quieted_at.nil?
      assert_not cached.key?('quieted_at')
    end

    it 'sets and clears an updated-at time' do
      @subject.set_attributes(updated_at: Time.now.utc)
      cached = Sidekiq.redis { |c| c.hgetall(@subject.cache_key) }
      assert @subject.updated_at
      assert_equal @subject.updated_at.to_i.to_s, cached['updated_at']

      @subject.set_attributes(updated_at: nil)
      cached = Sidekiq.redis { |c| c.hgetall(@subject.cache_key) }
      assert @subject.updated_at.nil?
      assert_not cached.key?('updated_at')
    end
  end

  describe 'sync_attributes' do
    it 'syncs attributes with cached values' do
      dynos = 2
      quieted_to = 1
      quieted_at = Time.now.utc - 10
      updated_at = quieted_at + 1
      @subject2.set_attributes(dynos: dynos, quieted_to: quieted_to, quieted_at: quieted_at, updated_at: updated_at)
      @subject.sync_attributes

      assert_equal dynos, @subject.dynos
      assert_equal_times quieted_to, @subject.quieted_to
      assert_equal_times quieted_at, @subject.quieted_at
      assert_equal_times updated_at, @subject.updated_at
      assert_equal_times @subject2.started_at, @subject.started_at
    end

    it 'syncs empty attributes from the cache' do
      @subject2.set_attributes(dynos: 2, quieted_to: 2, quieted_at: Time.now.utc, updated_at: Time.now.utc)
      @subject.sync_attributes
      assert @subject.dynos
      assert @subject.quieted_to
      assert @subject.quieted_at
      assert @subject.updated_at
      assert @subject.started_at

      @subject2.set_attributes(dynos: nil, quieted_to: nil, quieted_at: nil, updated_at: nil)
      @subject.sync_attributes
      assert_not @subject.dynos
      assert_not @subject.quieted_to
      assert_not @subject.quieted_at
      assert_not @subject.updated_at
      assert_not @subject.started_at
    end
  end

  describe 'quietdown' do
    it 'assigns a downscale target' do
      @subject.quietdown(1)
      assert_equal 1, @subject.quieted_to
      assert @subject.quieted_at
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

  describe 'wait_for_update!' do
    it 'returns true when updated since last activity' do
      @subject.updated_at = Time.now.utc - 10
      @subject.active_at = @subject.updated_at - 1
      assert @subject.wait_for_update!
    end

    # it 'returns false when throttled' do
    #   @subject.throttle = 10
    #   @subject.updated_at = Time.now.utc - 9
    #   @subject.active_at = @subject.updated_at - 1
    #   assert_not @subject.wait_for_update!
    # end

    # it 'returns false when a syncronized update is throttled' do
    #   @subject.throttle = 10
    #   @subject.updated_at = Time.now.utc - 15
    #   @subject2.touch(Time.now.utc - 9)
    #   assert_not @subject.wait_for_update!(@subject.updated_at + 1)
    #   assert_equal_times @subject.updated_at, @subject2.updated_at
    # end

    it 'returns true when updated' do
      mock = MiniTest::Mock.new.expect(:call, 0)
      @subject.stub(:update!, mock) do
        @subject.throttle = 10
        @subject.updated_at = Time.now.utc - 11
        @subject.active_at = @subject.updated_at + 1
        assert @subject.wait_for_update!
      end
      mock.verify
    end
  end

  # describe 'wait_for_shutdown!' do
  #   it 'returns false when throttled' do
  #     @subject.throttle = 10
  #     @subject.updated_at = Time.now.utc - 9
  #     assert_not @subject.wait_for_shutdown!
  #   end

  #   it 'returns false when a syncronized update is throttled' do
  #     @subject.throttle = 10
  #     @subject.updated_at = Time.now.utc - 15
  #     @subject2.touch(Time.now.utc - 9)
  #     assert_not @subject.wait_for_shutdown!
  #     assert_equal_times @subject.updated_at, @subject2.updated_at
  #   end

  #   it 'returns false when update returns dynos' do
  #     mock = MiniTest::Mock.new.expect(:call, 1)
  #     @subject.stub(:update!, mock) do
  #       @subject.throttle = 10
  #       @subject.updated_at = Time.now.utc - 11
  #       assert_not @subject.wait_for_shutdown!
  #     end
  #     mock.verify
  #   end

  #   it 'returns false when update returns no dynos, but uptime has not been met' do
  #     mock = MiniTest::Mock.new.expect(:call, 0)
  #     @subject.stub(:update!, mock) do
  #       @subject.throttle = 10
  #       @subject.updated_at = Time.now.utc - 11
  #       @subject.minimum_uptime = 10
  #       @subject.startup_at = Time.now.utc - 9
  #       assert_not @subject.wait_for_shutdown!
  #     end
  #     mock.verify
  #   end

  #   it 'returns true when update returns no dynos and uptime has been met' do
  #     mock = MiniTest::Mock.new.expect(:call, 0)
  #     @subject.stub(:update!, mock) do
  #       @subject.throttle = 10
  #       @subject.updated_at = Time.now.utc - 11
  #       @subject.minimum_uptime = 10
  #       @subject.startup_at = Time.now.utc - 11
  #       assert @subject.wait_for_shutdown!
  #     end
  #     mock.verify
  #   end
  # end

  # describe 'update!' do
  #   before do
  #     stub_heroku_api(@subject)
  #   end

  #   it 'sets startup time when unset with workers' do
  #     @subject.startup_at = nil
  #     assert_not @subject.startup_at

  #     @subject.update!(0, 0)
  #     assert_not @subject.startup_at

  #     @subject.update!(1, 1)
  #     assert @subject.startup_at
  #   end

  #   it 'does not modify an existing startup time' do
  #     timestamp = Time.now.utc - 10
  #     @subject.startup_at = timestamp
  #     @subject.update!(1, 1)
  #     assert_equal_times timestamp, @subject.startup_at
  #   end

  #   it 'returns current dynos while idle' do
  #     assert_equal 2, @subject.update!(2, 2)
  #   end

  #   it 'returns target dynos when upscaling' do
  #     assert_equal 2, @subject.update!(1, 2)
  #   end

  #   it 'sets unset startup time when upscaling' do
  #     @subject.startup_at = nil
  #     @subject.update!(1, 2)
  #     assert @subject.startup_at
  #   end

  #   it 'does not modify an existing startup time when upscaling' do
  #     timestamp = Time.now.utc - 10
  #     @subject.startup_at = timestamp
  #     @subject.update!(1, 2)
  #     assert_equal_times timestamp, @subject.startup_at
  #   end
  # end

  def stub_heroku_api(subject, dynos=0)
    subject.instance_variable_set(:@dyno_count, dynos)
    def subject.get_dyno_count; @dyno_count; end
    def subject.set_dyno_count(n); nil; end
  end
end