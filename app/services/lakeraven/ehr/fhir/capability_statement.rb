# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # The server's CapabilityStatement, served at /metadata.
      #
      # Built from an explicit map rather than scraped from the router, because a
      # Rails route does not tell you whether a FHIR interaction actually works:
      # Condition has a `show` route that always 404s, and several types are
      # index-only. A map can be wrong, so the spec checks it against the wire in
      # BOTH directions -- a declared capability that does not work fails, and a
      # working capability that is undeclared fails too. Drift breaks the build
      # rather than misleading a client.
      #
      # The rule this exists to honour: never advertise more than is granted. The
      # SMART discovery document already does that with wildcard write scopes, and
      # this document must not repeat it.
      class CapabilityStatement
        READ_AND_SEARCH = %w[
          Patient Practitioner AllergyIntolerance MedicationRequest Medication
          Observation DiagnosticReport CarePlan Encounter Consent
        ].freeze

        # Routed and searchable, but no working instance read: Condition's show
        # always 404s, and the rest are index-only in config/routes.rb.
        SEARCH_ONLY = %w[
          Condition ServiceRequest Immunization Measure MeasureReport ValueSet
        ].freeze

        # Instance read only -- no type-level search route.
        READ_ONLY = %w[Organization Location].freeze

        # Both a read and a search exist, and AuditEvent is listed separately
        # only to keep the reason visible: it is readable and searchable like the
        # clinical types, but it is not clinical data.
        AUDIT = %w[AuditEvent].freeze

        CREATE_ALLOWED = %w[Patient].freeze

        # Declared only where the parameter is actually honoured. Patient's list
        # is exactly what resolve_patient_search implements.
        SEARCH_PARAMS = {
          "Patient" => %w[_id identifier name birthdate gender]
        }.freeze

        def self.call(...) = new(...).to_fhir

        def to_fhir
          {
            resourceType: "CapabilityStatement",
            # FHIR status is the publication state of THIS DOCUMENT, not a
            # claim about the data. That the dataset is synthetic is disclosed in
            # implementation.description below, which is where a reader looks for
            # facts about the instance.
            status: "active",
            date: Date.current.iso8601,
            kind: "instance",
            software: { name: "Lakeraven EHR" },
            implementation: {
              description: "Lakeraven EHR FHIR API. This instance serves a " \
                           "synthetic dataset: invented records at an invented " \
                           "facility, containing no real patient data."
            },
            fhirVersion: "4.0.1",
            # Both the FHIR shorthand and the mime type: a client may match
            # on either, and the shorthand is what the spec for this element
            # expects.
            format: %w[json application/fhir+json],
            rest: [ { mode: "server", security: security, resource: resources } ]
          }
        end

        private

        # Deliberately NOT the SMART scopes_supported list, which advertises
        # wildcards this server will not grant. Only the SMART service URIs
        # belong here.
        def security
          {
            service: [ {
              coding: [ {
                system: "http://terminology.hl7.org/CodeSystem/restful-security-service",
                code: "SMART-on-FHIR"
              } ]
            } ]
          }
        end

        def resources
          (READ_AND_SEARCH + AUDIT).map { |t| entry(t, read: true, search: true) } +
            SEARCH_ONLY.map { |t| entry(t, read: false, search: true) } +
            READ_ONLY.map { |t| entry(t, read: true, search: false) }
        end

        def entry(type, read:, search:)
          codes = []
          codes << "read" if read
          codes << "search-type" if search
          codes << "create" if CREATE_ALLOWED.include?(type)

          resource = { type: type, interaction: codes.map { |c| { code: c } } }
          params = SEARCH_PARAMS[type]
          resource[:searchParam] = params.map { |n| { name: n, type: "string" } } if params
          resource
        end
      end
    end
  end
end
