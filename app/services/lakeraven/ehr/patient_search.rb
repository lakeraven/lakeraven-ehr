# frozen_string_literal: true

module Lakeraven
  module EHR
    # Patient search service.
    #
    # The single entry point for finding patients in the EHR. Reads
    # tenant and facility scope from Lakeraven::EHR::Current per
    # ADR 0003 (fail-loud if tenant is unset), delegates the actual
    # search to the configured adapter, and returns plain hashes
    # whose shape is documented on Adapters::Base#search_patients.
    #
    #   Lakeraven::EHR::PatientSearch.call(name: "DOE")
    #   Lakeraven::EHR::PatientSearch.call(identifier_system: "...", identifier_value: "...")
    #
    # The result hashes use the *_identifier convention from ADR 0004
    # and never expose backend-native ids — that's enforced at the
    # adapter level and asserted in the cucumber feature.
    class PatientSearch
      def self.call(name: nil, identifier_system: nil, identifier_value: nil, date_of_birth: nil)
        new.call(
          name: name,
          identifier_system: identifier_system,
          identifier_value: identifier_value,
          date_of_birth: date_of_birth
        )
      end

      def call(name: nil, identifier_system: nil, identifier_value: nil, date_of_birth: nil)
        tenant = Current.tenant_identifier
        if tenant.nil? || tenant.to_s.empty?
          raise MissingTenantContextError,
            "PatientSearch requires Lakeraven::EHR::Current.tenant_identifier to be set " \
            "(see ADR 0003 — fail-loud tenancy)"
        end

        EHR.adapter.search_patients(
          tenant_identifier: tenant,
          facility_identifier: Current.facility_identifier,
          name: name,
          identifier_system: identifier_system,
          identifier_value: identifier_value,
          date_of_birth: date_of_birth
        )
      end
    end
  end
end
