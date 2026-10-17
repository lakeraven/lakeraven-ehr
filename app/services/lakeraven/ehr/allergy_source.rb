# frozen_string_literal: true

module Lakeraven
  module EHR
    # The chart's `safe` helper turns both a raise and a genuine [] into [].
    # Allergy display must not: [] is "none recorded" and a raise is "not
    # loaded". Other clinical sections still use `safe`.
    class AllergySource
      attr_reader :records, :status

      def self.unauthorized
        new([], :unauthorized)
      end

      def self.fetch(log_label:)
        value = yield
        return new([], :error) unless value.is_a?(Array)

        new(value, :ok)
      rescue StandardError => e
        # Class only. The message from a supplemental provider includes the
        # patient identifier, and a name would be worse.
        Rails.logger.warn("#{log_label} allergy source failed: #{e.class}")
        new([], :error)
      end

      def self.bundle(records)
        {
          resourceType: "Bundle",
          type: "collection",
          total: records.length,
          entry: records.map { |record| { resource: record.to_fhir } }
        }
      end

      def initialize(records, status)
        @records = records
        @status = status
      end

      def ok?
        status == :ok
      end
    end
  end
end
