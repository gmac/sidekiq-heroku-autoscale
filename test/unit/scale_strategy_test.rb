require 'test_helper'

class ScaleStrategyTest < Minitest::Test
	def setup
		@sys = MockQueueSystem.new
		@subject = ::Sidekiq::HerokuAutoscale::ScaleStrategy
	end

  def test_binary_activates_when_work_present
    @sys.total_work = 1
    subject = @subject.new(max_workers: 1)
    assert_equal 1, subject.binary(@sys)
  end

  def test_binary_scales_to_maximum_workers
    @sys.total_work = 10
    subject = @subject.new(max_workers: 2)
    assert_equal 2, subject.binary(@sys)
  end

  def test_binary_scale_caps_at_actual_work
    @sys.total_work = 1
    subject = @subject.new(max_workers: 2)
    assert_equal 1, subject.binary(@sys)
  end

  def test_binary_deactivates_when_no_work
    @sys.total_work = 0
    subject = @subject.new(max_workers: 1)
    assert_equal 0, subject.binary(@sys)
  end

  def test_linear_activates_when_work_present
    @sys.total_work = 1
    subject = @subject.new(max_workers: 1)
    assert_equal 1, subject.linear(@sys)
  end

  def test_linear_deactivates_when_no_work
    @sys.total_work = 0
    subject = @subject.new(max_workers: 1)
    assert_equal 0, subject.linear(@sys)
  end

  def test_linear_minimally_scales_with_light_work
    @sys.total_work = 1
    subject = @subject.new(max_workers: 2, worker_capacity: 2)
    assert_equal 1, subject.linear(@sys)
  end

  def test_linear_maximally_scales_with_heavy_work
    @sys.total_work = 5
    subject = @subject.new(max_workers: 2, worker_capacity: 2)
    assert_equal 2, subject.linear(@sys)
  end

  def test_linear_proportionally_scales_with_moderate_work
    @sys.total_work = 5
    subject = @subject.new(max_workers: 5, worker_capacity: 2)
    assert_equal 3, subject.linear(@sys)
  end

  def test_linear_does_not_scale_below_minimum_factor
    @sys.total_work = 2
    subject = @subject.new(max_workers: 10, worker_capacity: 4, min_factor: 0.5)
    assert_equal 0, subject.linear(@sys)
  end

  def test_linear_scales_proprotionally_to_minimum_factor
    @sys.total_work = 3
    subject = @subject.new(max_workers: 10, worker_capacity: 4, min_factor: 0.5)
    assert_equal 1, subject.linear(@sys)
  end

  def test_linear_scales_maximally_to_minimum_factor
    @sys.total_work = 25
    subject = @subject.new(max_workers: 5, worker_capacity: 4, min_factor: 0.5)
    assert_equal 5, subject.linear(@sys)
  end

  def test_linear_scales_proprotionally_to_minimum_above_one
    @sys.total_work = 12
    subject = @subject.new(max_workers: 5, worker_capacity: 4, min_factor: 2)
    assert_equal 2, subject.linear(@sys)
  end

  def test_linear_scales_maximally_to_minimum_factor_above_one
    @sys.total_work = 30
    subject = @subject.new(max_workers: 5, worker_capacity: 4, min_factor: 2)
    assert_equal 5, subject.linear(@sys)
  end

  def test_linear_does_not_downscale_engaged_workers
    @sys.workers = 2
    subject = @subject.new(max_workers: 5, worker_capacity: 4)
    assert_equal 2, subject.linear(@sys)
  end

  def test_linear_does_not_scale_above_max_workers
    @sys.total_work = 40
    @sys.workers = 6
    subject = @subject.new(max_workers: 5, worker_capacity: 4)
    assert_equal 5, subject.linear(@sys)
  end

  def test_linear_returns_zero_for_zero_capacity
    @sys.total_work = 0
    @sys.workers = 0
    subject = @subject.new(max_workers: 0, worker_capacity: 0)
    assert_equal 0, subject.linear(@sys)
  end
end