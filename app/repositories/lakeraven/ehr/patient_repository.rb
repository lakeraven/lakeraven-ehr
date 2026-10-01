# frozen_string_literal: true

module Lakeraven
  module EHR
    # Access layer: hydrates Patient domain objects from RPMS (via rpms-rpc)
    # and optionally FHIR (via rpms-rpc MockFhirClient or IRIS for Health).
    #
    # Layer contract:
    # - Only this class calls PatientGateway / DataMapper for patient data
    # - Outputs Patient domain objects with provenance metadata
    # - source_preference controls read path (:rpc_only, :fhir_first, :rpc_first)
    # - Single source decision per invocation (no ad-hoc mixing)
    class PatientRepository
      SOURCE_PREFERENCES = %i[rpc_only fhir_first rpc_first].freeze

      class << self
        def find(dfn, source_preference: :rpc_only)
          return nil if dfn.blank? || dfn.to_i <= 0

          patient, source = fetch_patient(dfn.to_i, source_preference)
          return nil unless patient

          build_patient(patient, source: source)
        end

        def search(name_pattern, source_preference: :rpc_only)
          results = PatientGateway.search(name_pattern.to_s)
          results.map { |p| attach_provenance(p, source: :rpc) }
        end

        def find_by_ssn(ssn)
          return nil if ssn.blank?

          patient = PatientGateway.find_by_ssn(ssn)
          return nil unless patient

          attach_provenance(patient, source: :rpc)
        end

        private

        def fetch_patient(dfn, source_preference)
          case source_preference
          when :fhir_first
            patient = try_fhir(dfn)
            return [ patient, :fhir ] if patient

            patient = PatientGateway.find(dfn)
            [ patient, :rpc ]
          when :rpc_first
            patient = PatientGateway.find(dfn)
            return [ patient, :rpc ] if patient

            patient = try_fhir(dfn)
            [ patient, :fhir ]
          else # :rpc_only
            [ PatientGateway.find(dfn), :rpc ]
          end
        end

        def try_fhir(dfn)
          return nil unless fhir_available?

          fhir_data = RpmsRpc.fhir_client.read("Patient", dfn.to_s)
          return nil if fhir_data.nil? || fhir_data["resourceType"] == "OperationOutcome"

          patient = Patient.from_fhir(fhir_data)
          normalize_from_fhir!(patient) if patient
          patient
        rescue => e
          Rails.logger.warn("PatientRepository: FHIR read failed for DFN #{dfn}: #{e.message}")
          nil
        end

        def fhir_available?
          RpmsRpc.respond_to?(:fhir_client) && RpmsRpc.fhir_client.present?
        rescue
          false
        end

        def normalize_from_fhir!(patient)
          # Upcase name to VistA convention
          patient.name = patient.name&.upcase if patient.name.present?

          # Compute age from birthDate
          if patient.dob.present? && patient.age.blank?
            patient.age = ((Date.current - patient.dob).to_i / 365.25).to_i
          end
        end

        def build_patient(patient, source: :rpc)
          patient.provenance = build_provenance(source)
          patient
        end

        def attach_provenance(patient, source: :rpc)
          return nil unless patient

          patient.provenance = build_provenance(source)
          patient
        end

        def build_provenance(source = :rpc)
          {
            rpms: { source: source, fetched_at: Time.current, stale_after: 1.hour.from_now }
          }
        end
      end
    end
  end
end
