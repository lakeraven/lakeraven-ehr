# frozen_string_literal: true

module Lakeraven
  module EHR
    # Access layer: hydrates Patient domain objects from RPMS (via rpms-rpc)
    # and PostgreSQL (via ActiveRecord). Hidden behind Patient class methods.
    #
    # Layer contract: only this class calls DataMapper/AR for patient data.
    # Domain objects (Patient) are immutable after construction.
    class PatientRepository
      class << self
        def find(dfn)
          return nil if dfn.blank? || dfn.to_i <= 0

          rpms_core = fetch_rpms_core(dfn.to_i)
          return nil unless rpms_core

          build_patient(rpms_core)
        end

        def search(name_pattern)
          results = PatientGateway.search(name_pattern.to_s)
          results.map { |p| attach_provenance(p) }
        end

        def find_by_ssn(ssn)
          return nil if ssn.blank?

          patient = PatientGateway.find_by_ssn(ssn)
          return nil unless patient

          attach_provenance(patient)
        end

        private

        def fetch_rpms_core(dfn)
          patient = PatientGateway.find(dfn)
          return nil unless patient

          patient
        end

        def build_patient(patient)
          patient.provenance = build_provenance
          patient
        end

        def attach_provenance(patient)
          return nil unless patient

          patient.provenance = build_provenance
          patient
        end

        def build_provenance
          {
            rpms: { source: :rpc, fetched_at: Time.current, stale_after: 1.hour.from_now }
          }
        end
      end
    end
  end
end
