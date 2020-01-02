module Sidekiq
  module HerokuAutoscale

    class QueueSystem
      ALL_QUEUES = '*'.freeze

      attr_accessor :watch_queues, :include_retrying, :include_scheduled

      def initialize(watch_queues: ALL_QUEUES, include_retrying: true, include_scheduled: true)
        @watch_queues = [watch_queues].flatten.uniq
        @include_retrying = include_retrying
        @include_scheduled = include_scheduled
        @quiet = false
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

      def quiet!
        @quiet = true
        ::Sidekiq::ProcessSet.new.each(&:quiet!)
      end

    private

      def sidekiq_queues
        ::Sidekiq::Stats.new.queues
      end

      def count_jobs(job_set)
        return job_set.size if all_queues?
        job_set.count { |j| watch_queues.include?(j.queue) }
      end
    end

  end
end
