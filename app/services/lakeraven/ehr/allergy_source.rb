# frozen_string_literal: true

module Lakeraven
  module EHR
    # The chart's `safe` helper turns both a raise and a genuine [] into [].
    # Allergy display must not. A raise is "not loaded". [] is "none
    # recorded" only when the reading says ORQQAL assessed NKA, nothing was
    # dropped, and the merged list is empty — for_patient returns [] for
    # NKA, not-assessed, and an indeterminate reply alike.
    class AllergySource
      attr_reader :records, :status, :dropped_count

      def self.unauthorized
        new([], :unauthorized)
      end

      def self.fetch(log_label:)
        value = yield
        return failure unless value.is_a?(Array)

        new(
          value,
          :ok,
          verified_absence: absence_verified?(value),
          dropped_count: dropped_count_of(value)
        )
      rescue StandardError => e
        # Class only. The message from a supplemental provider includes the
        # patient identifier, and a name would be worse.
        Rails.logger.warn("#{log_label} allergy source failed: #{e.class}")
        failure
      end

      def self.bundle(records)
        {
          resourceType: "Bundle",
          type: "collection",
          total: records.length,
          entry: records.map { |record| { resource: record.to_fhir } }
        }
      end

      def initialize(records, status, verified_absence: false, dropped_count: 0)
        @records = records
        @status = status
        @verified_absence = verified_absence
        @dropped_count = dropped_count.to_i
      end

      def ok?
        status == :ok
      end

      def verified_absence?
        @verified_absence
      end

      # Banner and chart both ask here, so "none recorded" is one decision.
      def to_list_status(filtered_names)
        AllergyListStatus.from_counts(
          source_status: status,
          source_count: records.length,
          filtered_names: filtered_names,
          verified_absence: verified_absence?,
          dropped_count: dropped_count
        )
      end

      def self.failure
        new([], :error)
      end
      private_class_method :failure

      # A plain Array (a stub that only has records) cannot prove an empty
      # list is NKA. Only the reading carries that.
      def self.absence_verified?(value)
        value.is_a?(AllergyIntoleranceReading) && value.verified_absence?
      end
      private_class_method :absence_verified?

      def self.dropped_count_of(value)
        return 0 unless value.is_a?(AllergyIntoleranceReading)

        value.dropped_count
      end
      private_class_method :dropped_count_of
    end
  end
end
