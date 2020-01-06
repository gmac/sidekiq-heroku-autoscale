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
      # this may include one-or-more instances of one-or-more heroku process types
      # (though they should all be one process type if setup validation was observed)
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

      def any_quiet?
        sidekiq_processes.any?(&:stopping?)
      end

      # When scaling down workers, heroku stops the one with the highest number...
      # from https://stackoverflow.com/questions/25215334/scale-down-specific-heroku-worker-dynos
      def quietdown!(scale)
        quieted = false
        # processes have hostnames formatted as "worker.1", "worker.2", "sidekiq.1", etc...
        # this groups processes by type, then sorts by number, and then quiets beyond scale.
        sidekiq_processes.group_by { |p| p['hostname'].split('.').first }.each_pair do |type, group|
          # there should only ever be a single group here (assuming setup validations were observed)
          group.sort_by { |p| p['hostname'].split('.').last.to_i }.each_with_index do |process, index|
            if index + 1 > scale && !process.stopping?
              process.quiet!
              quieted = true
            end
          end
        end

        quieted
      end

      def sidekiq_queues
        ::Sidekiq::Stats.new.queues
      end

      def sidekiq_processes
        process_set = ::Sidekiq::ProcessSet.new
        # select all processes with queues that intersect watched queues
        process_set = process_set.select { |p| (p['queues'] & @watch_queues).any? } unless all_queues?
        process_set
      end

    private

      def count_jobs(job_set)
        return job_set.size if all_queues?
        job_set.count { |j| watch_queues.include?(j.queue) }
      end
    end

  end
end
