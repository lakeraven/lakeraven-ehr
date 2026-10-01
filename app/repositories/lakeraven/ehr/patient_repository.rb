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
          attach_tribal_detail(patient)
          attach_contact_detail(patient)
          patient
        end

        # Tribal detail lives in #9000001 (^AUPNPAT) and is read separately via
        # DDR GETS ENTRY DATA -- ORWPT ID INFO does not carry it, and an earlier
        # mapping that claimed it did was corrected. RPMS stores it, so we
        # surface it rather than leaving the chart thinner than the system we
        # replace.
        #
        # Here and NOT in `search`: this is a second broker round trip, so it
        # runs for a single-patient read, never once per row of a result set.
        #
        # Fail SOFT. A tribal read that errors must not take down a chart that
        # otherwise loaded -- the patient's clinical record does not depend on
        # it. The failure is logged rather than swallowed silently, because an
        # empty field and an unavailable source are different facts.
        def attach_tribal_detail(patient)
          return patient if patient.nil?
          return patient if patient.tribal_enrollment_number.present?

          details = TribalEnrollmentGateway.enrollment_details(patient.dfn)
          return patient if details.blank?

          patient.tribal_enrollment_number = details[:enrollment_number]
          patient.tribal_affiliation = details[:tribe_name]
          patient
        end

        # Telecom comes from VistA PATIENT #2 fields .131/.132/.133/.134, read
        # via DDR GETS ENTRY DATA. RpmsRpc::Patient.contact already wraps it,
        # and its own notes record WHY: the cellular phone (.134) is served by
        # no purpose-built registered RPC, so DDR is the read path.
        #
        # ADDRESS is deliberately NOT set here. Patient carries address_line1 /
        # city / state / zip_code, and RPMS does store them, but no field map
        # for them is sourced in this codebase -- and the mapping provenance
        # rule is that nothing invents a response layout. See lakeraven-ehr#564.
        #
        # Same placement and same fail-soft rule as the tribal read: a single
        # patient read, never per row of a search, and a contact read that
        # errors must not take down a chart that otherwise loaded.
        def attach_contact_detail(patient)
          return patient if patient.nil?
          return patient if patient.phone.present?

          contact = PatientGateway.contact(patient.dfn)
          return patient if contact.blank?

          patient.phone = contact[:phone_home].presence || contact[:phone_cell].presence
          patient
        rescue StandardError => e
          Rails.logger.warn(
            "[patient] contact detail unavailable for dfn=#{patient.dfn}: #{e.class}: #{e.message}"
          )
          patient
        rescue StandardError => e
          Rails.logger.warn(
            "[patient] tribal detail unavailable for dfn=#{patient.dfn}: #{e.class}: #{e.message}"
          )
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
