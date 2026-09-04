# frozen_string_literal: true

module Lakeraven
  module EHR
    # In-memory Encounter store (mirrors ProvenanceStore). The appointment
    # RPC path (ORWPT APPTLST) carries only datetime/location/status — it
    # cannot carry participants or reason codes — so a deployment that can
    # source richer encounters (e.g. from PCC visit context, or a
    # synthetic-sandbox fixture set) seeds Encounter models here and they are
    # served through the same Encounter serialization and search filters.
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

      def all
        @records.dup
      end

      # Matches ONLY the canonical owner (Encounter#owner_patient_id) — never
      # either owner field independently, so a record belongs to exactly one
      # patient's search.
      def for_patient(dfn)
        @records.select { |e| e.owner_patient_id == dfn.to_s }
      end

      def find(id)
        @records.find { |e| (e.fhir_id.presence || e.ien&.to_s) == id.to_s }
      end

      def count
        @records.count
      end
    end
  end
end
