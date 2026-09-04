# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory CarePlan store (mirrors EncounterStore). CarePlan has no
    # verified live RPC read path — a deployment that can source care plans
    # (e.g. a synthetic-sandbox fixture set) seeds CarePlan models here and
    # they are served through the same CarePlan serializer, search filters,
    # and read-by-id path.
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

      def all
        @records.dup
      end

      def for_patient(dfn)
        @records.select { |cp| cp.patient_dfn.to_s == dfn.to_s }
      end

      def find(id)
        @records.find { |cp| cp.ien.to_s == id.to_s }
      end

      def count
        @records.count
      end
    end
  end
end
