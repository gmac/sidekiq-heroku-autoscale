require 'test_helper'

describe 'Sidekiq::HerokuAutoscale::QueueSystem' do
  before do
    Sidekiq.redis {|c| c.flushdb }
    @subject = ::Sidekiq::HerokuAutoscale::QueueSystem
  end

  it 'initializes with options' do
    subject = @subject.new(watch_queues: %w[default low])
    assert_equal %w[default low], subject.watch_queues
    assert subject.include_retrying
    assert subject.include_scheduled

    subject = @subject.new(watch_queues: '*', include_retrying: false, include_scheduled: false)
    assert_equal %w[*], subject.watch_queues
    assert_not subject.include_retrying
    assert_not subject.include_scheduled
  end

  it 'assesses all_queues? status' do
    subject = @subject.new(watch_queues: '*')
    assert subject.all_queues?

    subject = @subject.new(watch_queues: %w[*])
    assert subject.all_queues?

    subject = @subject.new(watch_queues: %w[default low])
    assert_not subject.all_queues?
  end

  describe 'dynos' do
    it 'counts all dynos while empty' do
      subject = @subject.new(watch_queues: '*')
      assert_equal 0, subject.dynos
    end

    it 'counts all dynos while running' do
      subject = @subject.new(watch_queues: '*')
      process_workers('worker.1' => %w[default low], 'worker.2' => %w[high])
      assert_equal 2, subject.dynos
    end

    it 'counts select dynos while empty' do
      subject = @subject.new(watch_queues: %w[default low])
      assert_equal 0, subject.dynos
    end

    it 'counts select dynos while running' do
      subject = @subject.new(watch_queues: %w[default low])
      process_workers('worker.1' => %w[default], 'worker.2' => %w[low high], 'worker.3' => %w[high])
      assert_equal 2, subject.dynos
    end
  end

  describe 'threads' do
    it 'counts all threads while empty' do
      subject = @subject.new(watch_queues: '*')
      assert_equal 0, subject.threads
    end

    it 'counts all threads while empty' do
      subject = @subject.new(watch_queues: '*')
      process_workers('worker.1' => %w[default low], 'worker.2' => %w[high])
      assert_equal 3, subject.threads
    end

    it 'counts select threads while empty' do
      subject = @subject.new(watch_queues: %w[default low])
      assert_equal 0, subject.threads
    end

    it 'counts select threads when present' do
      subject = @subject.new(watch_queues: %w[default low])
      process_workers('worker.1' => %w[default low low high], 'worker.2' => %w[low high])
      assert_equal 4, subject.threads
    end
  end

  describe 'enqueued' do
    it 'counts all queues while empty' do
      subject = @subject.new(watch_queues: '*')
      assert_equal 0, subject.enqueued
    end

    it 'counts all queues with jobs present' do
      subject = @subject.new(watch_queues: '*')
      enqueue_jobs(%w[default default low])
      assert_equal 3, subject.enqueued
    end

    it 'counts select queues while empty' do
      subject = @subject.new(watch_queues: %w[default])
      assert_equal 0, subject.enqueued
    end

    it 'counts select queues with jobs present' do
      subject = @subject.new(watch_queues: %w[default])
      enqueue_jobs(%w[default default low])
      assert_equal 2, subject.enqueued
    end
  end

  describe 'scheduled' do
    it 'counts all scheduled while empty' do
      subject = @subject.new(watch_queues: '*')
      assert_equal 0, subject.scheduled
    end

    it 'counts all scheduled with jobs' do
      subject = @subject.new(watch_queues: '*')
      schedule_jobs(%w[default low])
      assert_equal 2, subject.scheduled
    end

    it 'counts all scheduled with ignore' do
      subject = @subject.new(watch_queues: '*', include_scheduled: false)
      schedule_jobs(%w[default low])
      assert_equal 0, subject.scheduled
    end

    it 'counts select scheduled while empty' do
      subject = @subject.new(watch_queues: %[default])
      assert_equal 0, subject.scheduled
    end

    it 'counts select scheduled with jobs' do
      subject = @subject.new(watch_queues: %[default])
      schedule_jobs(%w[default low])
      assert_equal 1, subject.scheduled
    end

    it 'counts select scheduled with ignore' do
      subject = @subject.new(watch_queues: %[default], include_scheduled: false)
      schedule_jobs(%w[default low])
      assert_equal 0, subject.scheduled
    end
  end

  describe 'retrying' do
    it 'counts all retrying while empty' do
      subject = @subject.new(watch_queues: '*')
      assert_equal 0, subject.retrying
    end

    it 'counts all retrying with jobs' do
      subject = @subject.new(watch_queues: '*')
      retry_jobs(%w[default low])
      assert_equal 2, subject.retrying
    end

    it 'counts all retrying with ignore' do
      subject = @subject.new(watch_queues: '*', include_retrying: false)
      retry_jobs(%w[default low])
      assert_equal 0, subject.retrying
    end

    it 'counts select retrying while empty' do
      subject = @subject.new(watch_queues: %[default])
      assert_equal 0, subject.retrying
    end

    it 'counts select retrying with work' do
      subject = @subject.new(watch_queues: %[default])
      retry_jobs(%w[default low])
      assert_equal 1, subject.retrying
    end

    it 'counts select retrying with ignore' do
      subject = @subject.new(watch_queues: %[default], include_retrying: false)
      retry_jobs(%w[default low])
      assert_equal 0, subject.retrying
    end
  end

  describe 'total_work' do
    it 'counts up all types of work' do
      subject = @subject.new(watch_queues: '*')
      process_workers('worker.1' => %w[default])
      enqueue_jobs(%w[default])
      schedule_jobs(%w[default])
      retry_jobs(%w[default])
      assert_equal 4, subject.total_work
    end
  end

  describe 'has_work?' do
    it 'has no work while empty' do
      subject = @subject.new(watch_queues: '*')
      assert_not subject.has_work?
    end

    it 'has work while active' do
      subject = @subject.new(watch_queues: '*')
      enqueue_jobs(%w[default])
      assert subject.has_work?
    end
  end

  describe 'quietdown!' do
    it 'has no effect when quieting above current process count' do
      subject = @subject.new(watch_queues: '*')
      process_workers('worker.1' => %w[default])
      stub_quietable(subject) do
        assert_not subject.quietdown!(2)
        assert_not subject.sidekiq_processes.find(&:stopping?)
      end
    end

    it 'has no effect when quieting at current process count' do
      subject = @subject.new(watch_queues: '*')
      process_workers('worker.1' => %w[default])
      stub_quietable(subject) do
        assert_not subject.quietdown!(1)
        assert_not subject.sidekiq_processes.find(&:stopping?)
      end
    end

    it 'quiets a single process down to zero' do
      subject = @subject.new(watch_queues: '*')
      process_workers('worker.1' => %w[default])
      stub_quietable(subject) do
        assert subject.quietdown!(0)
        assert subject.sidekiq_processes.find(&:stopping?)
      end
    end

    it 'quiets multiple processes above a threshold' do
      subject = @subject.new(watch_queues: '*')
      process_workers('worker.3' => %w[low], 'worker.1' => %w[low], 'worker.2' => %w[low])
      stub_quietable(subject) do
        assert subject.quietdown!(1)
        assert_not subject.sidekiq_processes.find { |p| p['hostname'] == 'worker.1' }.stopping?
        assert subject.sidekiq_processes.find { |p| p['hostname'] == 'worker.2' }.stopping?
        assert subject.sidekiq_processes.find { |p| p['hostname'] == 'worker.3' }.stopping?
      end
    end
  end

  def enqueue_jobs(queues)
    [queues].flatten.each do |queue|
      ::Sidekiq::Client.enqueue_to(queue, TestWorker, SecureRandom.uuid)
    end
  end

  def schedule_jobs(queues)
    [queues].flatten.each do |queue|
      ::Sidekiq::Client.enqueue_to_in(queue, 60, TestWorker, SecureRandom.uuid)
    end
  end

  def retry_jobs(queues)
    [queues].flatten.each do |queue|
      payload = Sidekiq.dump_json({ 'queue' => queue, 'class' => TestWorker, 'args' => [SecureRandom.uuid] })
      Sidekiq.redis { |c| c.zadd('retry', Time.now.to_f.to_s, payload) }
    end
  end

  # per sidekiq gem tests
  # https://github.com/mperham/sidekiq/blob/master/test/test_api.rb#L567
  def process_workers(queues_by_process)
    # { 'worker.1' => ['default'], 'worker.2' => ['low'] }
    queues_by_process.each_with_index do |(process_name, queues), pindex|
      key = "#{process_name}:#{ pindex }"
      pdata = { 'pid' => pindex, 'hostname' => process_name, 'queues' => queues, 'started_at' => Time.now.to_f }
      Sidekiq.redis do |c|
        c.sadd('processes', key)
        c.hmset(key, 'info', Sidekiq.dump_json(pdata), 'busy', 0, 'beat', Time.now.to_f, 'quiet', process_name.start_with?('quiet'))
      end

      queues.each_with_index do |queue, tindex|
        wdata = { 'queue' => queue, 'payload' => {}, 'run_at' => Time.now.to_f }
        Sidekiq.redis { |c| c.hmset("#{key}:workers", "1#{pindex}#{tindex}", Sidekiq.dump_json(wdata)) }
      end
    end
  end

  # allows process instances to have `quiet!` called without a sidekiq server
  # (stubs each process instance's quiet! method with self-assigning state)
  def stub_quietable(subject, &block)
    # map all process objects with self-flagging quiet! stubs
    quietable_processes = subject.sidekiq_processes.map do |process|
      def process.quiet!; @attribs['quiet'] = 'true'; end
      process
    end

    # stub the modified process instances onto the subject
    subject.stub(:sidekiq_processes, quietable_processes, &block)
  end
end