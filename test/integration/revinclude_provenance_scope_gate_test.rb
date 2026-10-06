# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # GATE SPEC — _revinclude=Provenance:target must not return Provenance unless the
    # credential also grants system/Provenance.read (grant-boundary on included types).
    class RevincludeProvenanceScopeGateTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      PATIENT_DFN = "1"
      VITALS_TAKEN = DateTime.new(2026, 2, 1, 9, 30, 0)

      class FakeObservationGateway
        def initialize(rows) = @rows = rows
        def for_patient(_dfn) = @rows
      end

      setup do
        ProvenanceStore.reset_instance!
        @saved_observation_gateway = Observation.gateway
        Observation.gateway = FakeObservationGateway.new([
          { type: "BP", value: "128/82", units: "mm[Hg]", recorded_date: VITALS_TAKEN }
        ])
        seed_patient_provenance!
        seed_observation_provenance!
      end

      teardown do
        teardown_smart_auth
        Observation.gateway = @saved_observation_gateway
        ProvenanceStore.reset_instance!
      end

      # Catches removing the Provenance scope gate while keeping _revinclude support.
      test "Patient search _revinclude includes Provenance when system/Provenance.read is granted" do
        setup_smart_auth(scopes: "system/Patient.read system/Provenance.read")
        get "/lakeraven-ehr/Patient",
          params: { _id: PATIENT_DFN, _revinclude: "Provenance:target" },
          headers: @headers

        # Catches treating missing Provenance scope as a hard search failure.
        assert_response :ok
        body = JSON.parse(response.body)
        provenance = provenance_bundle_entries(body)
        # Catches "fix" that disables _revinclude entirely instead of gating on scope.
        refute_empty provenance,
          "positive control: _revinclude must still emit Provenance when the scope is granted"
        provenance.each do |entry|
          # Catches Provenance entries not tagged as revinclude results.
          assert_equal "include", entry.dig("search", "mode"),
            "catches Provenance folded into match mode instead of revinclude"
          # Catches returning a different resource type in the include slot.
          assert_equal "Provenance", entry.dig("resource", "resourceType")
        end
        # Catches suppressing matched Patients when only the include is unauthorized.
        refute_empty patient_match_entries(body),
          "catches a fix that drops the whole search instead of withholding includes"
      end

      # Catches appending Provenance whenever _revinclude is present (delete-the-guard regression).
      test "Patient search _revinclude omits Provenance when only system/Patient.read is granted" do
        setup_smart_auth(scopes: "system/Patient.read")
        get "/lakeraven-ehr/Patient",
          params: { _id: PATIENT_DFN, _revinclude: "Provenance:target" },
          headers: @headers

        # Catches 403 on the whole search when Provenance.read is missing (wrong failure mode).
        assert_response :ok,
          "withheld revinclude must not fail the search with 403 — only drop Provenance entries"
        body = JSON.parse(response.body)
        # Catches delete-the-guard: appending Provenance without can_read?(Provenance).
        assert_empty provenance_bundle_entries(body),
          "catches leaking Provenance (and agent references) to a Patient.read-only token"
        matches = patient_match_entries(body)
        # Catches empty searchset when the revinclude is dropped.
        refute_empty matches,
          "catches rejecting the search instead of returning matched Patients"
        # Catches wrong patient or spurious filtering beyond the include.
        assert_equal PATIENT_DFN, matches.first.dig("resource", "id"),
          "catches returning an empty Bundle when the include is withheld"
      end

      # Catches Observation revinclude path missing the same Provenance.read gate as Patient.
      test "Observation search _revinclude includes Provenance when system/Provenance.read is granted" do
        setup_smart_auth(scopes: "system/Observation.read system/Provenance.read")
        get "/lakeraven-ehr/Observation",
          params: { patient: PATIENT_DFN, code: "85354-9", _revinclude: "Provenance:target" },
          headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        provenance = provenance_bundle_entries(body)
        refute_empty provenance,
          "positive control: Observation _revinclude must emit Provenance when scope is granted"
        provenance.each do |entry|
          # Catches Observation path omitting search.mode include on Provenance.
          assert_equal "include", entry.dig("search", "mode")
          assert_equal "Provenance", entry.dig("resource", "resourceType")
        end
        refute_empty observation_match_entries(body),
          "catches suppressing matched Observations when Provenance is allowed"
      end

      # Catches provenance_includes ignoring can_read?(Provenance) (delete-the-guard regression).
      test "Observation search _revinclude omits Provenance when only system/Observation.read is granted" do
        setup_smart_auth(scopes: "system/Observation.read")
        get "/lakeraven-ehr/Observation",
          params: { patient: PATIENT_DFN, code: "85354-9", _revinclude: "Provenance:target" },
          headers: @headers

        # Catches 403 on Observation search when Provenance.read is absent.
        assert_response :ok,
          "withheld revinclude must not fail the search with 403 — only drop Provenance entries"
        body = JSON.parse(response.body)
        # Catches provenance_includes ignoring can_read?(Provenance).
        assert_empty provenance_bundle_entries(body),
          "catches leaking Provenance to an Observation.read-only token"
        matches = observation_match_entries(body)
        refute_empty matches,
          "catches rejecting the search instead of returning matched Observations"
        assert_equal "85354-9", matches.first.dig("resource", "code", "coding", 0, "code"),
          "catches returning an empty Bundle when the include is withheld"
      end

      private

      def seed_patient_provenance!
        ProvenanceStore.instance.add(Provenance.new(
          fhir_id: "prov-patient-#{PATIENT_DFN}",
          target_type: "Patient",
          target_id: "rpms-#{PATIENT_DFN}",
          recorded: VITALS_TAKEN,
          activity: "CREATE",
          agent_who_type: "Practitioner",
          agent_who_id: "101",
          agent_type: "author"
        ))
      end

      def seed_observation_provenance!
        bp_id = "vital-#{PATIENT_DFN}-bp-#{VITALS_TAKEN.strftime('%Y%m%d%H%M')}"
        ProvenanceStore.instance.add(Provenance.new(
          fhir_id: "prov-#{bp_id}",
          target_type: "Observation",
          target_id: bp_id,
          recorded: VITALS_TAKEN,
          agent_who_type: "Practitioner",
          agent_who_id: "101",
          agent_type: "performer"
        ))
      end

      def provenance_bundle_entries(body)
        Array(body["entry"]).select do |entry|
          entry.dig("resource", "resourceType") == "Provenance"
        end
      end

      def patient_match_entries(body)
        Array(body["entry"]).select do |entry|
          entry.dig("resource", "resourceType") == "Patient" &&
            entry.dig("search", "mode") == "match"
        end
      end

      def observation_match_entries(body)
        Array(body["entry"]).select do |entry|
          entry.dig("resource", "resourceType") == "Observation" &&
            entry.dig("search", "mode") == "match"
        end
      end
    end
  end
end
