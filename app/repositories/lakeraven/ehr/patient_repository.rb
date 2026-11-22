# frozen_string_literal: true

module Lakeraven
  module EHR
    # Access layer: hydrates Patient domain objects from RPMS (via rpms-rpc)
    # and optionally FHIR, through the engine's configured FHIR client
    # (Lakeraven::EHR.configuration.fhir_client: FHIR::Client for an endpoint
    # such as IRIS for Health, FHIR::MockClient in tests).
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

        # A FHIR read ends one of three ways (#599):
        #   [:patient, patient]  the requested Patient, mapped and named
        #   [:absent]            no client, or a not-found/deleted OperationOutcome
        #   [:failure, reason]   anything else; reason is PHI-free
        # A failure is never "no such patient": when RPC has no patient
        # either, it raises Client::Error.
        def fetch_patient(dfn, source_preference)
          case source_preference
          when :fhir_first
            outcome, value = read_fhir(dfn)
            return [ value, :fhir ] if outcome == :patient

            patient = PatientGateway.find(dfn)
            raise_failure(value) if patient.nil? && outcome == :failure
            [ patient, :rpc ]
          when :rpc_first
            patient = PatientGateway.find(dfn)
            return [ patient, :rpc ] if patient

            outcome, value = read_fhir(dfn)
            raise_failure(value) if outcome == :failure
            [ value, :fhir ]
          else # :rpc_only
            [ PatientGateway.find(dfn), :rpc ]
          end
        end

        def read_fhir(dfn)
          return [ :absent ] unless fhir_available?

          answer = fhir_client.read("Patient", dfn.to_s)
          return [ :absent ] if absent_outcome?(answer)

          patient_outcome(answer, dfn)
        rescue Lakeraven::EHR::FHIR::Client::Error => e
          # Client::Error messages carry no id, params or body.
          fhir_failure(e.message)
        rescue StandardError => e
          # The class only: a message can carry a response body or patient data.
          fhir_failure(e.class.name)
        end

        def patient_outcome(answer, dfn)
          return fhir_failure("not the requested Patient") unless requested_patient?(answer, dfn)

          patient = map_patient(answer)
          return fhir_failure("could not be mapped") unless patient
          return fhir_failure("no usable name") if patient.name.blank?

          normalize_from_fhir!(patient)
          [ :patient, patient ]
        end

        # One warn per failure, with a reason that names no patient.
        def fhir_failure(reason)
          Rails.logger.warn("PatientRepository: FHIR Patient read failed (#{reason})")
          [ :failure, reason ]
        end

        def raise_failure(reason)
          raise Lakeraven::EHR::FHIR::Client::Error, "FHIR Patient read failed (#{reason})", cause: nil
        end

        def map_patient(answer)
          Patient.from_fhir(answer)
        rescue StandardError
          # A malformed resource, e.g. Date::Error on a partial birthDate.
          nil
        end

        def absent_outcome?(answer)
          answer.is_a?(Hash) &&
            answer["resourceType"] == "OperationOutcome" &&
            Array(answer["issue"]).any? { |issue| issue.is_a?(Hash) && %w[not-found deleted].include?(issue["code"]) }
        end

        def requested_patient?(answer, dfn)
          answer.is_a?(Hash) &&
            answer["resourceType"] == "Patient" &&
            answer["id"] == dfn.to_s
        end

        def fhir_client
          Lakeraven::EHR.configuration.fhir_client
        end

        def fhir_available?
          !fhir_client.nil?
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
