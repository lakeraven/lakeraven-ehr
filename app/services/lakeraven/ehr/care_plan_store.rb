# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory care plan store for FHIR CarePlan reads without an RPC path.
    # Replaces CarePlan lookups with a plain Ruby collection.
    class CarePlanStore
      def initialize
        @records = []
      end

      def self.instance
        @instance ||= new
      end

      def self.reset_instance!
        @instance = new
      end

      def add(care_plan)
        @records << care_plan
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
        @records.select { |care_plan| care_plan.patient_dfn.to_s == dfn.to_s }
      end

      def find(id)
        @records.find { |care_plan| care_plan.ien.to_s == id.to_s }
      end

      def count
        @records.count
      end
    end
  end
end
