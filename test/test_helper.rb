require 'bundler/setup'
Bundler.require(:default, :test)

require 'minitest/pride'
require 'minitest/autorun'
require 'sidekiq_heroku_autoscale'

REDIS = Sidekiq.redis = Sidekiq::RedisConnection.create(:url => 'redis://localhost:9736')

class TestQueueSystem
  attr_accessor :total_work, :dynos

  def initialize
    @total_work = 0
    @dynos = 0
  end

  def has_work?
    total_work > 0
  end
end

class TestWorker
  include Sidekiq::Worker
end

def assert_not(val)
  assert !val
end