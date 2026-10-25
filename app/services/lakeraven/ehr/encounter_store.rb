# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory encounter store for FHIR Encounter reads without an RPC path.
    # Replaces Encounter lookups with a plain Ruby collection.
    # An encounter is owned by patient_identifier, its FHIR subject.
    class EncounterStore
      def initialize
        @records = []
      end

      def self.instance
        @instance ||= new
      end

      def self.reset_instance!
        @instance = new
      end

      def add(encounter)
        validate(encounter)
        @records << encounter
      end

      def clear!
        @records.clear
      end

      def seed!(records)
        raise ArgumentError, "records must be an Array" unless records.is_a?(Array)

        records.each { |encounter| validate(encounter) }
        @records = records.dup
      end

      def all
        @records.dup
      end

      def for_patient(dfn)
        return [] if dfn.blank?

        @records.select { |encounter| encounter.patient_identifier.to_s == dfn.to_s }
      end

      def find(id)
        @records.find { |encounter| encounter.ien.to_s == id.to_s }
      end

      def count
        @records.count
      end

      private

      def validate(encounter)
        raise ArgumentError, "record is nil" if encounter.nil?

        identifier = encounter.patient_identifier
        raise ArgumentError, "patient_identifier is blank" if identifier.blank?

        dfn = encounter.patient_dfn
        return if dfn.blank?

        raise ArgumentError, "patient_dfn does not match patient_identifier" if dfn.to_s != identifier.to_s
      end
    end
  end
end
