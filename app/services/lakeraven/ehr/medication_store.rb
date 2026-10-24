# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory medication store for definitional FHIR Medication resources.
    # Holds records keyed by fhir_id; medications are not patient-scoped.
    class MedicationStore
      def initialize
        @records = []
      end

      def self.instance
        @instance ||= new
      end

      def self.reset_instance!
        @instance = new
      end

      def add(medication)
        validate(medication)
        @records << medication
      end

      def clear!
        @records.clear
      end

      def seed!(records)
        raise ArgumentError, "records must be an Array" unless records.is_a?(Array)

        records.each { |medication| validate(medication) }
        @records = records.dup
      end

      def all
        @records.dup
      end

      def find(id)
        @records.find { |medication| medication.fhir_id.to_s == id.to_s }
      end

      def count
        @records.count
      end

      private

      def validate(medication)
        raise ArgumentError, "record is nil" if medication.nil?
        raise ArgumentError, "fhir_id is blank" if medication.fhir_id.blank?
      end
    end
  end
end
