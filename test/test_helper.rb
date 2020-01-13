require 'bundler/setup'
Bundler.require(:default, :test)

require 'minitest/pride'
require 'minitest/autorun'
require 'sidekiq-heroku-autoscale'

Sidekiq.redis = Sidekiq::RedisConnection.create(:url => 'redis://localhost:9736')

FIXTURES_PATH = File.expand_path("../fixtures", __FILE__)

class TestQueueSystem
  attr_accessor :total_work, :dynos

  def initialize(total_work: 0, dynos: 0)
    @total_work = total_work
    @dynos = dynos
  end

  def has_work?
    total_work > 0
  end
end

class TestWorker
  include Sidekiq::Worker
end

class TestClient
  class List
    def list(app)
      raise 'not implemented'
    end

    def update(params)
      raise 'not implemented'
    end
  end

  def formation
    @formation ||= List.new
  end
end

def assert_not(val)
  assert !val
end

def assert_not_equal(exp, val)
  assert exp != val
end

def assert_equal_times(a, b)
  assert_equal a.to_i, b.to_i
end

def assert_raises_message(klass, pattern, &block)
  err = assert_raises(klass, &block)
  assert_match pattern, err.message
end