# frozen_string_literal: true

module Lakeraven
  module EHR
    module FHIR
      # The server's CapabilityStatement, served at /metadata (#574).
      #
      # Built from an explicit map, not scraped from the router: a route does
      # not say whether an interaction works. Condition has a show route that
      # always 404s, and a route can name a controller that does not exist.
      # A map can be wrong too, so the test checks it against the routes and
      # the wire in both directions: a declared capability that does not work
      # fails, and a routed one that is not declared fails.
      #
      # Search parameters come from SearchCapabilities, which is also what
      # FHIRSearchBundle enforces, so there is one list of them, not two.
      #
      # The security element comes from SmartDiscovery, which also builds
      # .well-known/smart-configuration, so the two name the same endpoints.
      # It names no scopes: smart-configuration lists them.
      class CapabilityStatement
        FHIR_VERSION = "4.0.1"
        US_CORE_IG = "http://hl7.org/fhir/us/core/ImplementationGuide/hl7.fhir.us.core|6.1.0"
        US_CORE = "http://hl7.org/fhir/us/core/StructureDefinition"

        # US Core 6.1.0 profiles, declared only for a type whose served output
        # the HL7 validator passes with no errors. test/us_core/validate.rb (the
        # "US Core" CI job) checks what the engine serves against every profile
        # declared here and fails on an error; a type joins this list when its
        # output validates, never before. The others are listed in that job's
        # report with their errors.
        US_CORE_PROFILES = {
          "Patient" => %w[us-core-patient],
          "Practitioner" => %w[us-core-practitioner],
          "Location" => %w[us-core-location],
          "AllergyIntolerance" => %w[us-core-allergyintolerance],
          "Condition" => %w[us-core-condition-problems-health-concerns],
          "MedicationRequest" => %w[us-core-medicationrequest],
          "Observation" => %w[us-core-vital-signs],
          "Immunization" => %w[us-core-immunization]
        }.transform_values { |names| names.map { |name| "#{US_CORE}/#{name}" }.freeze }.freeze
        SEARCH_ONLY_STUB = "No read by id: GET [type]/[id] is routed and always returns 404."

        # What each routed type supports, and where its data comes from:
        # integrators were told in prose which resources are live and which
        # are not, and this is where a client can read it.
        RESOURCES = {
          "Patient" => { interactions: %w[read search-type create], source: "RPMS, through rpms-rpc." },
          "Practitioner" => { interactions: %w[read search-type], source: "RPMS, through rpms-rpc." },
          "Organization" => { interactions: %w[read], source: "RPMS, through rpms-rpc." },
          "Location" => { interactions: %w[read], source: "RPMS, through rpms-rpc." },
          "AllergyIntolerance" => {
            interactions: %w[search-type],
            source: "RPMS, through rpms-rpc, plus a deployment's supplemental allergy provider when one is configured. " \
                    "#{SEARCH_ONLY_STUB}"
          },
          "Condition" => { interactions: %w[search-type], source: "RPMS, through rpms-rpc. #{SEARCH_ONLY_STUB}" },
          "MedicationRequest" => { interactions: %w[search-type], source: "RPMS, through rpms-rpc. #{SEARCH_ONLY_STUB}" },
          "Observation" => {
            interactions: %w[search-type],
            source: "Vital signs from RPMS, through rpms-rpc, plus a deployment's supplemental observation provider " \
                    "when one is configured. #{SEARCH_ONLY_STUB}"
          },
          "Encounter" => { interactions: %w[search-type], source: "RPMS, through rpms-rpc." },
          "ServiceRequest" => { interactions: %w[search-type], source: "RPMS referrals, through rpms-rpc." },
          "Immunization" => { interactions: %w[search-type], source: "RPMS, through rpms-rpc." },
          "Procedure" => { interactions: %w[search-type], source: "RPMS, through rpms-rpc." },
          "AuditEvent" => { interactions: %w[read search-type], source: "This server's own audit log." },
          "Measure" => { interactions: %w[search-type], source: "Measure definitions shipped with the engine." },
          "MeasureReport" => {
            interactions: %w[search-type], source: "Not served yet: a search always returns an empty Bundle."
          },
          "ValueSet" => {
            interactions: %w[read search-type],
            source: "ValueSet JSON files the host app contributes (TerminologyService.additional_valueset_paths). " \
                    "With IRIS or VSAC terminology configured, search returns an empty Bundle and read returns 404.",
            operations: [ { name: "expand", definition: "http://hl7.org/fhir/OperationDefinition/ValueSet-expand" } ]
          },
          "CoverageEligibilityRequest" => {
            interactions: %w[create],
            source: "Create takes patient_dfn, coverage_type, provider_npi, service_date and purpose as request " \
                    "parameters, not a CoverageEligibilityRequest resource, and returns the response the " \
                    "configured eligibility adapter gives."
          }
        }.freeze

        def self.call(...) = new(...).to_fhir

        def initialize(base_url:, token_endpoint:)
          @base_url = base_url
          @token_endpoint = token_endpoint
        end

        def to_fhir
          {
            resourceType: "CapabilityStatement",
            # The publication state of this document, not a claim about the
            # data.
            status: "active",
            date: Date.current.iso8601,
            kind: "instance",
            software: { name: "Lakeraven EHR", version: Lakeraven::EHR::VERSION },
            implementation: { description: implementation_description, url: @base_url },
            fhirVersion: FHIR_VERSION,
            implementationGuide: [ US_CORE_IG ],
            format: %w[json application/fhir+json],
            rest: [ {
              mode: "server",
              security: security,
              resource: RESOURCES.map { |type, declaration| resource(type, declaration) },
              searchParam: SearchCapabilities.rest_search_params
            } ]
          }
        end

        private

        # The engine cannot tell synthetic records from real ones on a live
        # RPMS, so it says so only when it knows: the in-process mock client
        # serves nothing but invented records.
        def implementation_description
          description = "Lakeraven EHR FHIR API over RPMS."
          return description unless mock_backend?

          "#{description} This instance serves a synthetic dataset from an in-process mock " \
            "of RPMS: invented records, no real patient data."
        end

        def mock_backend?
          defined?(RpmsRpc::MockClient) && BackendRegistry.current.client.is_a?(RpmsRpc::MockClient)
        end

        def security
          SmartDiscovery.new(token_endpoint: @token_endpoint).security
        end

        def resource(type, declaration)
          {
            type: type,
            documentation: declaration[:source],
            supportedProfile: US_CORE_PROFILES[type],
            interaction: declaration[:interactions].map { |code| { code: code } },
            operation: declaration[:operations]
          }.compact.merge(SearchCapabilities.resource_capabilities(type))
        end
      end
    end
  end
end
