# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory encounter store for FHIR Encounter reads without an RPC path.
    # Replaces Encounter lookups with a plain Ruby collection.
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
        @records << encounter
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

      def for_patient(dfn)
        @records.select { |encounter| encounter.patient_dfn.to_s == dfn.to_s }
      end

      def find(id)
        @records.find { |encounter| encounter.ien.to_s == id.to_s }
      end

      def count
        @records.count
      end
    end
  end
end
