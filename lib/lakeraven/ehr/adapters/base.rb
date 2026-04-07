# frozen_string_literal: true

module Lakeraven
  module EHR
    module Adapters
      # Abstract adapter for the EHR backend.
      #
      # The host application provides a concrete subclass that implements
      # the methods declared here. The reference implementation calls
      # rpms-rpc; alternative implementations can point at a FHIR server,
      # a fixture, or any other source of truth.
      #
      # Per ADR 0002 (PHI tokenization), every method on this contract
      # accepts opaque identifiers and returns plain hashes whose keys
      # use the *_identifier convention from ADR 0004. The engine never
      # persists the returned data — it serializes to FHIR at request
      # time and discards it.
      #
      # Per ADR 0003 (tenancy), every method takes a tenant_identifier
      # and (where applicable) a facility_identifier. The adapter
      # implementation is responsible for honoring those scopes when
      # talking to the backend.
      class Base
        # Search patients by name and/or FHIR Identifier.
        #
        # @param tenant_identifier [String] opaque tenant token
        # @param facility_identifier [String, nil] opaque facility token; nil = all facilities in tenant
        # @param name [String, nil] partial or full name (e.g. "DOE,JOHN", "DOE")
        # @param identifier_system [String, nil] FHIR Identifier system URI
        # @param identifier_value [String, nil] FHIR Identifier value
        # @param date_of_birth [Date, String, nil] DOB filter
        # @return [Array<Hash>] each result hash with keys :patient_identifier,
        #   :display_name, :date_of_birth, :gender, :facility_identifier
        def search_patients(tenant_identifier:, facility_identifier: nil, name: nil, identifier_system: nil, identifier_value: nil, date_of_birth: nil)
          raise NotImplementedError, "#{self.class} must implement #search_patients"
        end

        # Resolve a single patient by opaque identifier.
        #
        # @param tenant_identifier [String]
        # @param patient_identifier [String]
        # @return [Hash, nil] same shape as a search_patients result, or nil if not found
        def find_patient(tenant_identifier:, patient_identifier:)
          raise NotImplementedError, "#{self.class} must implement #find_patient"
        end

        # Search practitioners by name, specialty, and/or FHIR Identifier.
        #
        # @param tenant_identifier [String] opaque tenant token
        # @param facility_identifier [String, nil] opaque facility token; nil = all facilities
        # @param name [String, nil] partial or full name (case-insensitive substring)
        # @param specialty [String, nil] specialty / qualification text
        # @param identifier_system [String, nil] FHIR Identifier system URI (e.g. NPI)
        # @param identifier_value [String, nil] FHIR Identifier value
        # @return [Array<Hash>] each result with keys :practitioner_identifier,
        #   :display_name, :specialty, :facility_identifier, :identifiers
        def search_practitioners(tenant_identifier:, facility_identifier: nil, name: nil, specialty: nil, identifier_system: nil, identifier_value: nil)
          raise NotImplementedError, "#{self.class} must implement #search_practitioners"
        end

        # Resolve a single practitioner by opaque identifier.
        #
        # @param tenant_identifier [String]
        # @param practitioner_identifier [String]
        # @return [Hash, nil] same shape as a search_practitioners result, or nil if not found
        def find_practitioner(tenant_identifier:, practitioner_identifier:)
          raise NotImplementedError, "#{self.class} must implement #find_practitioner"
        end
      end
    end
  end
end
