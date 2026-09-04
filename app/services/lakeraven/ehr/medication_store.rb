# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory Medication store (mirrors ProvenanceStore). No mapped RPMS
    # RPC exposes the DRUG file (#50) as a readable formulary, so Medication
    # resources are seeded here by the deployment (e.g. a synthetic-sandbox
    # fixture set, or a future DDR-backed loader) and served through the
    # Medication serializer. Medication is a definitional resource — it
    # carries no per-patient PHI.
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

      def all
        @records.dup
      end

      def find(id)
        @records.find { |m| m.fhir_id.to_s == id.to_s }
      end

      def count
        @records.count
      end
    end
  end
end
