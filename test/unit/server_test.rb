require 'test_helper'

describe 'Sidekiq::HerokuAutoscale::Server' do
  before do
    @subject = ::Sidekiq::HerokuAutoscale::Server
  end

  it 'provides a thread-safe monitor instance' do
    t1 = Thread.new { @subject.monitor.object_id }.value
    t2 = Thread.new { @subject.monitor.object_id }.value
    assert_equal t1, t2
  end
end