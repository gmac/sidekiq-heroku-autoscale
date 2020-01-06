require 'test_helper'

describe 'Sidekiq::HerokuAutoscale::DynoManager' do
  before do
    Sidekiq.redis {|c| c.flushdb }
    @subject = ::Sidekiq::HerokuAutoscale::DynoManager.new({
      api_token: 'b33skn33s',
      app_name: 'test-this',
    })
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
      assert_equal timestamp.to_s, @subject.last_update.to_s
      assert_equal timestamp.to_s, ::Sidekiq.redis { |c| c.get(@subject.send(:redis_key, :touch)) }
    end
  end

  describe 'sync_touch!' do
    it 'does not sync from an empty cache' do
      @subject.last_update = nil
      assert_not @subject.sync_touch!
      assert @subject.last_update.nil?
    end

    it 'does not sync a cached value older than local' do
      timestamp = Time.now.utc
      @subject.touch(timestamp - 1)
      @subject.last_update = timestamp
      assert_not @subject.sync_touch!
      assert_equal timestamp.to_s, @subject.last_update.to_s
    end

    it 'syncs a cached value newer than local' do
      timestamp = Time.now.utc
      @subject.touch(timestamp)
      @subject.last_update = timestamp - 1
      assert @subject.sync_touch!
      assert_equal timestamp.to_s, @subject.last_update.to_s
    end

    it 'syncs any cached value when locally unset' do
      timestamp = Time.now.utc
      @subject.touch(timestamp)
      @subject.last_update = nil
      assert @subject.sync_touch!
      assert_equal timestamp.to_s, @subject.last_update.to_s
    end
  end

  describe 'ready_for_update?' do
    it 'checks if last update exceeds the throttle' do
      @subject.throttle = 10

      @subject.last_update = Time.now.utc - 9
      assert_not @subject.ready_for_update?

      @subject.last_update = Time.now.utc - 11
      assert @subject.ready_for_update?
    end

    it 'checks if last update is newer than the probe' do
      @subject.throttle = 10
      @subject.last_update = Time.now.utc - 15

      assert @subject.ready_for_update?(@subject.last_update + 1)
      assert_not @subject.ready_for_update?(@subject.last_update - 1)
    end

    it 'assimilates cached updates from other processes' do
      cached_time = Time.now.utc - 9
      local_time = Time.now.utc - 11
      @subject.throttle = 10
      @subject.touch(cached_time)
      @subject.last_update = local_time
      assert_not @subject.ready_for_update?
      assert_equal cached_time.to_s, @subject.last_update.to_s
    end

    it 'returns true for no blocking conditions' do
      assert @subject.ready_for_update?
    end
  end
end