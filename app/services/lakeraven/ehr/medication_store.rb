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
        @records << medication
      end

      def clear!
        @records.clear
      end

      def seed!(records)
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
    end
  end
end
