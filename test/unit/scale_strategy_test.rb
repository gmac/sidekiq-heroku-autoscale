require 'test_helper'

describe 'Sidekiq::HerokuAutoscale::ScaleStrategy' do
  before do
    @sys = TestQueueSystem.new
    @subject = ::Sidekiq::HerokuAutoscale::ScaleStrategy
  end

  it 'call_configures_via_mode_setting' do
    @sys.total_work = 5

    subject = @subject.new(mode: :binary, max_dynos: 5, workers_per_dyno: 2)
    assert_equal 5, subject.call(@sys)

    subject = @subject.new(mode: :linear, max_dynos: 5, workers_per_dyno: 2)
    assert_equal 3, subject.call(@sys)
  end

  describe 'binary' do
    it 'activates when work is present' do
      @sys.total_work = 1
      subject = @subject.new(max_dynos: 1)
      assert_equal 1, subject.binary(@sys)
    end

    it 'scales to maximum workers' do
      @sys.total_work = 10
      subject = @subject.new(max_dynos: 2)
      assert_equal 2, subject.binary(@sys)
    end

    it 'deactivates when no work is present' do
      @sys.total_work = 0
      subject = @subject.new(max_dynos: 1)
      assert_equal 0, subject.binary(@sys)
    end
  end

  describe 'linear' do
    it 'activates with some work' do
      @sys.total_work = 1
      subject = @subject.new(max_dynos: 1)
      assert_equal 1, subject.linear(@sys)
    end

    it 'deactivates with no work' do
      @sys.total_work = 0
      subject = @subject.new(max_dynos: 1)
      assert_equal 0, subject.linear(@sys)
    end

    it 'minimally scales with light work' do
      @sys.total_work = 1
      subject = @subject.new(max_dynos: 2, workers_per_dyno: 2)
      assert_equal 1, subject.linear(@sys)
    end

    it 'maximally scales with heavy work' do
      @sys.total_work = 5
      subject = @subject.new(max_dynos: 2, workers_per_dyno: 2)
      assert_equal 2, subject.linear(@sys)
    end

    it 'proportionally scales with moderate work' do
      @sys.total_work = 5
      subject = @subject.new(max_dynos: 5, workers_per_dyno: 2)
      assert_equal 3, subject.linear(@sys)
    end

    it 'does not scale until minimum is met' do
      @sys.total_work = 2
      subject = @subject.new(max_dynos: 10, workers_per_dyno: 4, min_factor: 0.5)
      assert_equal 0, subject.linear(@sys)
    end

    it 'scales proprotionally with a minimum' do
      @sys.total_work = 3
      subject = @subject.new(max_dynos: 10, workers_per_dyno: 4, min_factor: 0.5)
      assert_equal 1, subject.linear(@sys)
    end

    it 'scales maximally with a minimum' do
      @sys.total_work = 25
      subject = @subject.new(max_dynos: 5, workers_per_dyno: 4, min_factor: 0.5)
      assert_equal 5, subject.linear(@sys)
    end

    it 'scales proportionally with a minimum > 1' do
      @sys.total_work = 12
      subject = @subject.new(max_dynos: 5, workers_per_dyno: 4, min_factor: 2)
      assert_equal 2, subject.linear(@sys)
    end

    it 'scales maximally with a minimum factor > 1' do
      @sys.total_work = 30
      subject = @subject.new(max_dynos: 5, workers_per_dyno: 4, min_factor: 2)
      assert_equal 5, subject.linear(@sys)
    end

    it 'does not downscale engaged workers' do
      @sys.dynos = 2
      subject = @subject.new(max_dynos: 5, workers_per_dyno: 4)
      assert_equal 2, subject.linear(@sys)
    end

    it 'does not scale above max workers' do
      @sys.total_work = 40
      @sys.dynos = 6
      subject = @subject.new(max_dynos: 5, workers_per_dyno: 4)
      assert_equal 5, subject.linear(@sys)
    end

    it 'returns zero for zero capacity' do
      @sys.total_work = 0
      @sys.dynos = 0
      subject = @subject.new(max_dynos: 0, workers_per_dyno: 0)
      assert_equal 0, subject.linear(@sys)
    end
  end
end