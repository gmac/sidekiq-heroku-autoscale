module Sidekiq
  module HerokuAutoscale

    class ScaleStrategy
      attr_accessor :mode, :max_dynos, :min_dynos, :workers_per_dyno, :min_factor

      def initialize(mode: :binary, max_dynos: 1, min_dynos: 0, workers_per_dyno: 25, min_factor: 0)
        @mode = mode
        @max_dynos = max_dynos
        @min_dynos = min_dynos
        @workers_per_dyno = workers_per_dyno
        @min_factor = min_factor
      end

      def call(sys)
        case @mode.to_s
        when 'linear'
          linear(sys)
        else
          binary(sys)
        end
      end

      def binary(sys)
        sys.has_work? ? @max_dynos : 0
      end

      def linear(sys)
        # total capacity of max workers
        total_capacity = (@max_dynos * @workers_per_dyno).to_f

        # min capacity required to scale first worker
        min_capacity = [0, @min_factor].max.to_f * @workers_per_dyno

        # min percentage of total capacity
        min_capacity_percentage = min_capacity / total_capacity
        requested_capacity_percentage = sys.total_work / total_capacity

        # Scale requested capacity taking into account the minimum required
        scale_factor = (requested_capacity_percentage - min_capacity_percentage) / (total_capacity - min_capacity_percentage)
        scale_factor = 0 if scale_factor.nan? # Handle DIVZERO
        scaled_capacity_percentage = scale_factor * total_capacity

        # don't scale down past number of currently engaged workers,
        # and don't scale up past maximum dynos
        ideal_dynos = ([0, scaled_capacity_percentage].max * @max_dynos).ceil
        #minimum_dynos = [sys.dynos, ideal_dynos, @min_dynos].max
        minimum_dynos = [ideal_dynos, @min_dynos].max
        maximum_dynos = [minimum_dynos, @max_dynos].min
        [minimum_dynos, maximum_dynos].min
      end
    end

  end
end
