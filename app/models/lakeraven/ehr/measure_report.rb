# frozen_string_literal: true

module Lakeraven
  module EHR
    class MeasureReport
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :measure_id, :string
      attribute :patient_dfn, :string
      attribute :report_type, :string
      attribute :period_start, :date
      attribute :period_end, :date
      attribute :initial_population_count, :integer, default: 0
      attribute :denominator_count, :integer, default: 0
      attribute :numerator_count, :integer, default: 0
      attribute :exclusion_count, :integer, default: 0

      def performance_rate
        return 0.0 if denominator_count.zero?

        numerator_count.to_f / denominator_count
      end

      def to_fhir
        {
          resourceType: "MeasureReport",
          measure: measure_id,
          type: report_type,
          group: [ {
            population: [
              { code: { text: "initial-population" }, count: initial_population_count },
              { code: { text: "denominator" }, count: denominator_count },
              { code: { text: "numerator" }, count: numerator_count }
            ]
          } ]
        }
      end
    end
  end
end
