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

      def workers
        worker_set = ::Sidekiq::Workers.new
        worker_set = worker_set.select { |pid, tid, work| watch_queues.include?(work['queue']) } unless all_queues?
        worker_set.map { |pid, tid, work| pid }.uniq.size
      end

      def queued
        counts = all_queues? ? sidekiq_queues.values : sidekiq_queues.slice(*watch_queues).values
        counts.map(&:to_i).reduce(&:+) || 0
      end

      def scheduled
        return 0 unless @include_scheduled
        count_jobs(::Sidekiq::ScheduledSet.new)
      end

      def retrying
        return 0 unless @include_retrying
        count_jobs(::Sidekiq::RetrySet.new)
      end

      def total_work
        queued + scheduled + retrying + workers
      end

      def has_work?
        total_work > 0
      end

      def idle?
        !has_work?
      end

      def all_quiet?
        sidekiq_processes.all?(&:stopping?)
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
        process_set = ::Sidekiq::ProcessSet.new
        # select all processes with queues that intersect with watched queues
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
