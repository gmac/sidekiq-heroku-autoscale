require 'sidekiq/api'

module Sidekiq
  module HerokuAutoscale

    class QueueSystem
      ALL_QUEUES = '*'.freeze

      attr_accessor :watch_queues, :include_retrying, :include_scheduled

      def initialize(watch_queues: ALL_QUEUES, include_retrying: true, include_scheduled: true)
        @watch_queues = [watch_queues].flatten.uniq
        @include_retrying = include_retrying
        @include_scheduled = include_scheduled
      end

      def all_queues?
        @watch_queues.first == ALL_QUEUES
      end

      # number of dynos (process instances) running sidekiq
      # this may include one or more instances of one or more heroku process types
      def dynos
        sidekiq_processes.size
      end

      # number of worker threads currently running sidekiq jobs
      # counts all queue-specific threads across all dynos (process instances)
      def threads
        # work => { 'queue' => name, 'run_at' => timestamp, 'payload' => msg }
        worker_set = ::Sidekiq::Workers.new.to_a
        worker_set = worker_set.select { |pid, tid, work| watch_queues.include?(work['queue']) } unless all_queues?
        worker_set.length
      end

      # number of jobs sitting in the active work queue
      def enqueued
        counts = all_queues? ? sidekiq_queues.values : sidekiq_queues.slice(*watch_queues).values
        counts.map(&:to_i).reduce(&:+) || 0
      end

      # number of jobs in the scheduled set
      def scheduled
        return 0 unless @include_scheduled
        count_jobs(::Sidekiq::ScheduledSet.new)
      end

      # number of jobs in the retry set
      def retrying
        return 0 unless @include_retrying
        count_jobs(::Sidekiq::RetrySet.new)
      end

      def total_work
        enqueued + scheduled + retrying + threads
      end

      def has_work?
        total_work > 0
      end

      def idle?
        !has_work?
      end

      def all_quiet?
        memoized = sidekiq_processes
        memoized.size > 0 && memoized.all?(&:stopping?)
      end

      def quietdown!(scale)
        # processes have hostnames formatted as "worker.1", "worker.2", "sidekiq.1", etc...
        # this groups processes by their name, then sorts them by number, then quiets all beyond scale
        sidekiq_processes.group_by { |p| p['hostname'].split('.').first }.each do |group|
          group.sort_by { |p| p['hostname'].split('.').last.to_i }
            .reverse
            .take([group.length-scale, group.length].max)
            .each(&:quiet!)
        end
      end

    private

      def sidekiq_queues
        ::Sidekiq::Stats.new.queues
      end

      def sidekiq_processes
        # Process => {
        #   'hostname' => 'app-1.example.com',
        #   'started_at' => <process start time>,
        #   'pid' => 12345,
        #   'tag' => 'myapp'
        #   'concurrency' => 25,
        #   'queues' => ['default', 'low'],
        #   'busy' => 10,
        #   'beat' => <last heartbeat>,
        #   'identity' => <unique string identifying the process>,
        # }
        process_set = ::Sidekiq::ProcessSet.new
        # select all processes with queues that intersect watched queues
        process_set = process_set.select { |p| (p['queues'] & @watch_queues).any? } unless all_queues?
        process_set
      end

      def count_jobs(job_set)
        return job_set.size if all_queues?
        job_set.count { |j| watch_queues.include?(j.queue) }
      end
    end

  end
end
