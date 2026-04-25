# frozen_string_literal: true

module Lakeraven
  module EHR
    class MeasureReport
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      attribute :measure_id, :string
      attribute :patient_dfn, :string
      attribute :report_type, :string, default: "individual"
      attribute :period_start, :date
      attribute :period_end, :date
      attribute :initial_population_count, :integer, default: 0
      attribute :denominator_count, :integer, default: 0
      attribute :numerator_count, :integer, default: 0
      attribute :exclusion_count, :integer, default: 0

      validates :measure_id, presence: true
      validates :report_type, inclusion: { in: %w[individual summary] }

      def performance_rate
        return nil if denominator_count.zero?

        effective_denominator = denominator_count - exclusion_count
        return nil if effective_denominator <= 0

        (numerator_count.to_f / effective_denominator).round(4)
      end

      def id
        if report_type == "individual"
          "#{measure_id}-#{patient_dfn}"
        else
          "#{measure_id}-summary"
        end
      end

      def persisted?
        false
      end

      def as_json(*)
        to_fhir
      end

      def to_fhir
        {
          resourceType: "MeasureReport",
          id: id,
          status: "complete",
          type: report_type,
          measure: "Measure/#{measure_id}",
          subject: build_subject,
          period: build_period,
          group: build_groups
        }.compact
      end

      def self.resource_class
        "MeasureReport"
      end

      private

      def build_subject
        return nil unless report_type == "individual" && patient_dfn.present?

        { reference: "Patient/rpms-#{patient_dfn}" }
      end

      def build_period
        {
          start: period_start&.iso8601,
          end: period_end&.iso8601
        }
      end

      def build_groups
        [{
          population: build_population_entries,
          measureScore: build_measure_score
        }.compact]
      end

      def build_population_entries
        entries = []
        entries << build_population("initial-population", initial_population_count)
        entries << build_population("denominator", denominator_count)
        entries << build_population("numerator", numerator_count)
        entries << build_population("denominator-exclusion", exclusion_count) if exclusion_count > 0
        entries
      end

      def build_population(code, count)
        {
          code: { coding: [{ code: code }] },
          count: count
        }
      end

      def build_measure_score
        rate = performance_rate
        return nil if rate.nil?

        { value: rate }
      end
    end
  end
end
