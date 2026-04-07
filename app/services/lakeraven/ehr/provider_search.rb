# frozen_string_literal: true

module Lakeraven
  module EHR
    # Practitioner search service.
    #
    # Mirrors PatientSearch — single entry point that reads tenant
    # and facility scope from Lakeraven::EHR::Current per ADR 0003,
    # raises MissingTenantContextError if tenant is unset, and
    # delegates to the configured adapter's #search_practitioners.
    #
    #   Lakeraven::EHR::ProviderSearch.call(name: "MARTINEZ")
    #   Lakeraven::EHR::ProviderSearch.call(specialty: "Cardiology")
    #   Lakeraven::EHR::ProviderSearch.call(
    #     identifier_system: "http://hl7.org/fhir/sid/us-npi",
    #     identifier_value: "1234567890"
    #   )
    #
    # The result hashes use the *_identifier convention from ADR 0004
    # and never expose backend-native ids — that's enforced at the
    # adapter level and asserted in the cucumber feature.
    class ProviderSearch
      def self.call(name: nil, specialty: nil, identifier_system: nil, identifier_value: nil)
        new.call(
          name: name,
          specialty: specialty,
          identifier_system: identifier_system,
          identifier_value: identifier_value
        )
      end

      def call(name: nil, specialty: nil, identifier_system: nil, identifier_value: nil)
        tenant = Current.tenant_identifier
        if tenant.nil? || tenant.to_s.empty?
          raise MissingTenantContextError,
            "ProviderSearch requires Lakeraven::EHR::Current.tenant_identifier to be set " \
            "(see ADR 0003 — fail-loud tenancy)"
        end

        EHR.adapter.search_practitioners(
          tenant_identifier: tenant,
          facility_identifier: Current.facility_identifier,
          name: name,
          specialty: specialty,
          identifier_system: identifier_system,
          identifier_value: identifier_value
        )
      end
    end
  end
end
