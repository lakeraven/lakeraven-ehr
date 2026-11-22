# frozen_string_literal: true

module Lakeraven
  module EHR
    # Allergy display must not turn both a raise and a genuine [] into [].
    # A raise is "not loaded", and keeps its classified failure. [] is "none
    # recorded" only when the reading says ORQQAL assessed NKA, nothing was
    # dropped, and the merged list is empty — for_patient returns [] for
    # NKA, not-assessed, and an indeterminate reply alike.
    class AllergySource
      attr_reader :records, :status, :dropped_count, :failure

      def self.unauthorized
        new([], :unauthorized)
      end

      def self.fetch(log_label:)
        value = yield
        return not_a_list(value, log_label) unless value.is_a?(Array)

        new(
          value,
          :ok,
          verified_absence: absence_verified?(value),
          dropped_count: dropped_count_of(value),
          conflict: value.is_a?(AllergyIntoleranceReading) && value.conflict
        )
      rescue *RpmsReadFailure::PASS_THROUGH
        raise
      rescue StandardError => e
        # Never the message: one from a supplemental provider includes the
        # patient identifier, and a name would be worse.
        failure = RpmsReadFailure.new(e, noun: "allergies")
        failure.log(Rails.logger, "#{log_label} allergy source")
        errored(failure)
      end

      def self.bundle(records)
        {
          resourceType: "Bundle",
          type: "collection",
          total: records.length,
          entry: records.map { |record| { resource: record.to_fhir } }
        }
      end

      def initialize(records, status, verified_absence: false, dropped_count: 0, conflict: false, failure: nil)
        @records = records
        @status = status
        @verified_absence = verified_absence
        @dropped_count = dropped_count.to_i
        @conflict = conflict == true
        @failure = failure
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
          dropped_count: dropped_count,
          conflict: @conflict
        )
      end

      # A reply that is not a list is a failed read, not "none recorded".
      def self.not_a_list(value, log_label)
        failure = RpmsReadFailure.not_a_list(noun: "allergies", returned: value.class)
        failure.log(Rails.logger, "#{log_label} allergy source")
        errored(failure)
      end
      private_class_method :not_a_list

      def self.errored(failure = nil)
        new([], :error, failure: failure)
      end
      private_class_method :errored

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
