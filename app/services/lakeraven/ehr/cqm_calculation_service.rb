# frozen_string_literal: true

module Lakeraven
  module EHR
    class CqmCalculationService
      def initialize(conditions: [], observations: [])
        @conditions = conditions
        @observations = observations
      end

      def evaluate(measure_id, patient_dfn, period:)
        measure = Measure.find(measure_id)
        return nil unless measure

        patient_conditions = @conditions.select { |c| c.respond_to?(:dfn) ? c.dfn.to_s == patient_dfn.to_s : true }
        patient_observations = @observations.select { |o| o.respond_to?(:dfn) ? o.dfn.to_s == patient_dfn.to_s : true }

        in_pop = in_initial_population?(measure, patient_conditions)
        in_num = in_pop && meets_numerator?(measure, period, patient_observations)

        MeasureReport.new(
          measure_id: measure_id, patient_dfn: patient_dfn, report_type: "individual",
          period_start: period.begin, period_end: period.end,
          initial_population_count: in_pop ? 1 : 0,
          denominator_count: in_pop ? 1 : 0,
          numerator_count: in_num ? 1 : 0
        )
      end

      def evaluate_population(measure_id, patient_dfns, period:)
        reports = patient_dfns.map { |dfn| evaluate(measure_id, dfn, period: period) }

        MeasureReport.new(
          measure_id: measure_id, report_type: "summary",
          period_start: period.begin, period_end: period.end,
          initial_population_count: reports.sum(&:initial_population_count),
          denominator_count: reports.sum(&:denominator_count),
          numerator_count: reports.sum(&:numerator_count)
        )
      end

      private

      def in_initial_population?(measure, conditions)
        pop = measure.initial_population
        return false unless pop

        case pop["resource_type"]
        when "Patient"
          # Age-based: always true (age check simplified for now)
          true
        when "Condition"
          valueset = pop["valueset_id"]
          conditions.any? { |c| c.valueset_id == valueset }
        else
          false
        end
      end

      def meets_numerator?(measure, period, observations)
        num = measure.numerator
        return false unless num

        relevant_obs = observations.select do |o|
          o.effective_date >= period.begin && o.effective_date <= period.end
        end
        return false if relevant_obs.empty?

        # If threshold specified, compare most recent value
        if num["value_threshold"]
          most_recent = relevant_obs.max_by(&:effective_date)
          compare_value(most_recent.value, num["value_comparator"], num["value_threshold"])
        else
          # Presence-based: having any observation in period is sufficient
          true
        end
      end

      def compare_value(value, comparator, threshold)
        case comparator
        when "<" then value < threshold
        when "<=" then value <= threshold
        when ">" then value > threshold
        when ">=" then value >= threshold
        else false
        end
      end
    end
  end
end
