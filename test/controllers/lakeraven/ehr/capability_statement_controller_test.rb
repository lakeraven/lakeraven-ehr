# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # GATE SPEC: FHIR CapabilityStatement at /metadata — truthful, bidirectional
    # correspondence with the live REST surface (GAP 1).
    class CapabilityStatementControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      METADATA_PATH = "/lakeraven-ehr/metadata"
      FHIR_PREFIX = "/lakeraven-ehr"

      # Routed FHIR types that intentionally do not appear in /metadata (non-clinical
      # or not yet described in FHIR::CapabilityStatement).
      OMIT_FROM_CAPABILITY_METADATA_CROSSWALK = %w[
        CoverageEligibilityRequest Procedure
      ].freeze

      # Interactions that must never appear: this engine has no PUT/PATCH routes.
      FORBIDDEN_INTERACTION_CODES = %w[update patch delete].freeze
      CREATE_ALLOWED_TYPES = %w[Patient].freeze

      # Instance reads proved over HTTP only when this spec seeds probe data (same
      # contract as MedicationStore in setup). Types that declare `read` but have no
      # entry here still must expose a member GET route — absence of fixture data
      # must not be read as absence of capability.
      CAPABILITY_PROBE_ALLERGEN = "Penicillin"
      CAPABILITY_PROBE_APPOINTMENT_AT = DateTime.new(2026, 8, 12, 9, 0, 0)

      setup do
        setup_internal_smart_auth
        install_capability_read_probe_fixtures!
      end

      teardown do
        teardown_capability_read_probe_fixtures!
        teardown_smart_auth
      end

      # Catches routing/controller omission: metadata must exist and be FHIR JSON.
      test "GET metadata returns CapabilityStatement as application/fhir+json" do
        get METADATA_PATH

        assert_response :ok
        assert_equal "application/fhir+json", response.media_type
        body = JSON.parse(response.body)
        assert_equal "CapabilityStatement", body["resourceType"]
      end

      # FHIR discovery is specified without a Bearer token; SMART .well-known is
      # already public on this engine. Clinical reads stay authorized, but clients
      # and validators must read capabilities before they can authenticate.
      test "metadata is readable without authentication like SMART discovery" do
        get METADATA_PATH # deliberately no Authorization header

        assert_response :ok
      end

      # Catches a stub document missing required CapabilityStatement elements.
      test "metadata includes required CapabilityStatement elements" do
        get METADATA_PATH
        body = JSON.parse(response.body)

        assert_equal "active", body["status"]
        assert body["date"].present?, "CapabilityStatement.date is required"
        assert_equal "instance", body["kind"]
        assert body["fhirVersion"].present?, "CapabilityStatement.fhirVersion is required"
        assert_includes Array(body["format"]), "json"
        assert body["rest"].is_a?(Array), "CapabilityStatement.rest is required"
        assert body["rest"].any?, "CapabilityStatement.rest must not be empty"
      end

      # Catches repeating SMART discovery's mistake: advertising wildcards the
      # backend token endpoint never mints for typical registrations.
      test "metadata does not advertise ungrantable system wildcard write scopes" do
        get METADATA_PATH
        capability = JSON.parse(response.body)
        advertised = oauth_scope_strings_in(capability)

        refute_includes advertised, "system/*.write",
          "must not claim system/*.write unless every client can be minted that scope"
        refute_includes advertised, "system/*.*",
          "must not claim system/*.* unless every client can be minted that scope"
      end

      # Catches listing create/update on types the server refuses (no update routes).
      test "metadata does not claim forbidden write interactions" do
        get METADATA_PATH
        rest_resources = JSON.parse(response.body).fetch("rest").flat_map { |r| r["resource"] || [] }
        assert rest_resources.any?, "expected at least one rest.resource entry"

        rest_resources.each do |resource|
          codes = Array(resource["interaction"]).map { |i| i["code"] }
          (codes & FORBIDDEN_INTERACTION_CODES).each do |forbidden|
            flunk "CapabilityStatement claims #{forbidden} on #{resource['type']} but no route implements it"
          end
          if codes.include?("create") && CREATE_ALLOWED_TYPES.exclude?(resource["type"])
            flunk "CapabilityStatement claims create on #{resource['type']} but only Patient POST is implemented"
          end
        end
      end

      # Catches understating the deployed API: every routed FHIR type must appear.
      test "every routed FHIR resource type is listed in metadata" do
        capability = fetch_capability_statement
        listed = capability.fetch("rest").flat_map { |r| (r["resource"] || []).map { |e| e["type"] } }.uniq
        assert listed.any?, "CapabilityStatement must list resource types"

        missing = routed_fhir_resource_types_for_metadata - listed
        assert_empty missing,
          "routed FHIR types missing from CapabilityStatement: #{missing.join(', ')}"
      end

      # Catches overstating the API: a listed type must be reachable; declared
      # instance reads must be routed, and where this spec seeds probe data the
      # read must succeed on the wire (RPC-backed types need mock rows — not
      # inferring "no read" from an empty search).
      test "every resource type listed in metadata is routed and responds to HTTP" do
        capability = fetch_capability_statement
        listed = capability.fetch("rest").flat_map { |r| r["resource"] || [] }
        assert listed.any?, "CapabilityStatement must enumerate rest.resource"

        listed.each do |resource|
          type = resource["type"]
          interactions = Array(resource["interaction"]).map { |i| i["code"] }
          assert interactions.any?, "#{type} must declare at least one interaction"

          if interactions.include?("read")
            assert_instance_read_works!(type)
          end
          if interactions.include?("search-type")
            assert_type_search_works!(type)
          end
        end
      end

      # Catches decorative searchParam entries that are not honoured on the wire.
      test "every Patient searchParam declared in metadata is honoured via HTTP" do
        capability = fetch_capability_statement
        patient = capability.fetch("rest").flat_map { |r| r["resource"] || [] }
          .find { |e| e["type"] == "Patient" }
        assert patient, "CapabilityStatement must describe Patient"

        params = Array(patient["searchParam"]).map { |p| p["name"] }
        assert params.any?, "Patient must declare search parameters"

        probes = {
          "_id" => { _id: "1" },
          "identifier" => { identifier: "http://hl7.org/fhir/sid/us-ssn|111-11-1111" },
          "name" => { name: "Anderson" },
          "birthdate" => { name: "Anderson", birthdate: "1980-05-15" },
          "gender" => { name: "Anderson", gender: "female" }
        }

        params.each do |name|
          probe = probes.fetch(name) do
            flunk "CapabilityStatement lists Patient?#{name}= but this spec has no HTTP probe — add one"
          end
          get "#{FHIR_PREFIX}/Patient", params: probe, headers: @headers
          assert_response :ok, "Patient?#{name}= must be honoured"
          body = JSON.parse(response.body)
          assert_equal "Bundle", body["resourceType"]
          if name != "birthdate" && name != "gender"
            assert_operator body["total"].to_i, :>=, 1,
              "Patient?#{name}= probe must match seeded patient 1"
          end
        end
      end

      # Catches implemented Patient searches that are omitted from metadata (false negatives).
      test "implemented Patient search parameters are all declared in metadata" do
        capability = fetch_capability_statement
        patient = capability.fetch("rest").flat_map { |r| r["resource"] || [] }
          .find { |e| e["type"] == "Patient" }
        declared = Array(patient&.dig("searchParam")).map { |p| p["name"] }

        required = %w[_id identifier name birthdate gender]
        missing = required - declared
        assert_empty missing,
          "working Patient searches missing from CapabilityStatement: #{missing.join(', ')}"
      end

      private

      def fetch_capability_statement
        get METADATA_PATH
        assert_response :ok
        JSON.parse(response.body)
      end

      def routed_fhir_resource_types_for_metadata
        types = Set.new
        Lakeraven::EHR::Engine.routes.routes.each do |route|
          next unless %w[GET HEAD].include?(route.verb)

          type = fhir_path_resource_type(route.path.spec.to_s)
          next if type.nil? || OMIT_FROM_CAPABILITY_METADATA_CROSSWALK.include?(type)

          types << type
        end
        types.to_a.sort
      end

      def fhir_path_resource_type(path_spec)
        path_spec.split("/").find { |part| part.match?(/\A[A-Z][A-Za-z]+\z/) }
      end

      def install_capability_read_probe_fixtures!
        @instance_read_probes = {}

        MedicationStore.instance.add(
          Medication.new(fhir_id: "med-capability-probe", code: "999001",
                         display: "Capability probe medication")
        )

        client = RpmsRpc.client
        client.seed_keyed_collection(:allergy_list, "1", [
          { allergen: CAPABILITY_PROBE_ALLERGEN, reaction: "Hives", severity: "moderate" }
        ])
        client.seed_keyed_collection(:patient_appointments, "1", [
          { datetime: CAPABILITY_PROBE_APPOINTMENT_AT, location_ien: 1,
            location: "Primary Care Clinic", status: "CHECKED OUT" }
        ])
        client.seed_keyed_collection(:medication_list, "1", [
          { ien: 9001, drug_name: "Lisinopril 10mg", sig: "1 tab PO daily", status: "active" }
        ])

        CarePlanStore.instance.add(CarePlan.new(
          ien: "cp-capability-probe", patient_dfn: "1", title: "Capability probe care plan",
          status: "active", intent: "plan"
        ))
        DiagnosticReportStore.instance.add(DiagnosticReport.new(
          ien: "dr-capability-probe", patient_dfn: "1", category: "LAB",
          code: "4548-4", code_display: "Hemoglobin A1c", status: "final"
        ))

        audit = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1"
        )
        @capability_audit_event_id = audit.id

        allergy_id = "allergy-1-penicillin"
        # :patient_appointments field 0 is date-only (fileman_date); time is lost on
        # round-trip, so appointment_id always uses midnight for seeded datetimes.
        encounter_id = Encounter.send(
          :appointment_id, "1", { datetime: CAPABILITY_PROBE_APPOINTMENT_AT.to_date }
        )

        @instance_read_probes.merge!(
          "Patient" => "#{FHIR_PREFIX}/Patient/1",
          "Practitioner" => "#{FHIR_PREFIX}/Practitioner/101",
          "Organization" => "#{FHIR_PREFIX}/Organization/1",
          "Location" => "#{FHIR_PREFIX}/Location/1",
          "Medication" => "#{FHIR_PREFIX}/Medication/med-capability-probe",
          "AllergyIntolerance" => "#{FHIR_PREFIX}/AllergyIntolerance/#{allergy_id}",
          "Encounter" => "#{FHIR_PREFIX}/Encounter/#{encounter_id}",
          "CarePlan" => "#{FHIR_PREFIX}/CarePlan/cp-capability-probe",
          "DiagnosticReport" => "#{FHIR_PREFIX}/DiagnosticReport/dr-capability-probe",
          "AuditEvent" => "#{FHIR_PREFIX}/AuditEvent/#{audit.id}"
        )
      end

      def teardown_capability_read_probe_fixtures!
        client = RpmsRpc.client
        client.seed_keyed_collection(:allergy_list, "1", [])
        client.seed_keyed_collection(:patient_appointments, "1", [])
        client.seed_keyed_collection(:medication_list, "1", [])

        MedicationStore.reset_instance!
        CarePlanStore.reset_instance!
        DiagnosticReportStore.reset_instance!

        if @capability_audit_event_id
          AuditEvent.where(id: @capability_audit_event_id).delete_all
        end
      end

      def oauth_scope_strings_in(capability)
        security = capability.fetch("rest").flat_map { |r| Array(r["security"]) }
        security.to_json.scan(%r{(?:patient|user|system)/[^\s"\\]+})
      end

      def assert_instance_read_works!(type)
        path = instance_read_probe(type)
        unless path
          assert_member_read_route!(type)
          return
        end

        get path, headers: @headers
        assert response.media_type == "application/fhir+json", "#{type} read must return FHIR JSON"
        assert_equal 200, response.status, "#{type}/[id] read must succeed for a known instance"
        assert_equal type, JSON.parse(response.body)["resourceType"]
      end

      def assert_member_read_route!(type)
        probe_path = "#{FHIR_PREFIX}/#{type}/capability-route-probe"
        recognized = rails_routes.recognize_path(probe_path, method: :get)
        assert recognized[:controller].present?,
          "CapabilityStatement lists read on #{type} but no member GET route exists (#{probe_path})"
      rescue ActionController::RoutingError
        flunk "CapabilityStatement lists read on #{type} but no member GET route exists"
      end

      def rails_routes
        Rails.application.routes
      end

      def assert_type_search_works!(type)
        path, params = search_probe(type)
        assert path.present?, "CapabilityStatement lists search-type on #{type} but this spec has no probe"

        get path, params: params, headers: @headers
        assert_equal 200, response.status
        assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
      end

      def instance_read_probe(type)
        @instance_read_probes[type]
      end

      def search_probe(type)
        case type
        when "Patient" then [ "#{FHIR_PREFIX}/Patient", { name: "Anderson" } ]
        when "Practitioner" then [ "#{FHIR_PREFIX}/Practitioner", { name: "MARTINEZ" } ]
        when "Medication" then [ "#{FHIR_PREFIX}/Medication", {} ]
        when "Measure", "MeasureReport", "AuditEvent", "ValueSet"
          [ "#{FHIR_PREFIX}/#{type}", {} ]
        when "Organization", "Location" then [ nil, nil ]
        else
          [ "#{FHIR_PREFIX}/#{type}", { patient: "1" } ]
        end
      end
    end
  end
end
