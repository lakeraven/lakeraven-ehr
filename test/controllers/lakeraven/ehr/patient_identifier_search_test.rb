# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # GATE SPEC: US Core Patient?identifier= (GAP 2) — system|value semantics,
    # honest errors, SSN regression, org scoping parity with other search paths.
    class PatientIdentifierSearchTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      DFN_SYSTEM = "urn:oid:2.16.840.1.113883.4.349"
      US_SSN_SYSTEM = "http://hl7.org/fhir/sid/us-ssn"
      OID_SSN_SYSTEM = "urn:oid:2.16.840.1.113883.4.1"
      UNKNOWN_SYSTEM = "http://example.com/fhir/sid/not-a-patient-identifier"

      FOREIGN_DFN = "900002"
      FOREIGN_SITE_IEN = 8904

      setup do
        setup_internal_smart_auth
        seed_foreign_patient!
      end

      teardown do
        teardown_smart_auth
      end

      # Catches value-only SSN extraction that ignores the business identifier system.
      test "search by DFN system|value resolves the patient" do
        token = "#{DFN_SYSTEM}|1"
        get "/lakeraven-ehr/Patient", params: { identifier: token }, headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_operator body["total"].to_i, :>=, 1
        ids = body["entry"].map { |e| e.dig("resource", "id") }
        assert_includes ids, "1"
      end

      # Catches silent empty Bundle on unknown systems (false negative).
      test "search with an unknown identifier system returns OperationOutcome not empty success" do
        get "/lakeraven-ehr/Patient",
          params: { identifier: "#{UNKNOWN_SYSTEM}|no-such-value" },
          headers: @headers

        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-supported", body["issue"].first["code"],
          "unknown identifier systems must not masquerade as 'no patients found'"
      end

      # Catches regressions in the existing SSN search path.
      test "search by US Core SSN system|value continues to resolve the patient" do
        get "/lakeraven-ehr/Patient",
          params: { identifier: "#{US_SSN_SYSTEM}|111-11-1111" },
          headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_operator body["total"].to_i, :>=, 1
        assert_equal "1", body["entry"].first.dig("resource", "id")
      end

      test "search by OID SSN system|value continues to resolve the patient" do
        get "/lakeraven-ehr/Patient",
          params: { identifier: "#{OID_SSN_SYSTEM}|111-11-1111" },
          headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_operator body["total"].to_i, :>=, 1
        assert_includes body["entry"].map { |e| e.dig("resource", "id") }, "1"
      end

      # SPEC CHANGE -- the second assertion previously expected total 0. FHIR R4
      # token search matches `Identifier.value` irrespective of system, so a
      # bare value resolves against every recognised system and returns the
      # union. A bare SSN still resolves, which is what the legacy callers need.
      test "bare identifier value without system resolves across recognised systems" do
        get "/lakeraven-ehr/Patient", params: { identifier: "111-11-1111" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_operator body["total"].to_i, :>=, 1
        assert_equal "1", body["entry"].first.dig("resource", "id")

        get "/lakeraven-ehr/Patient", params: { identifier: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_operator body["total"].to_i, :>=, 1
        assert_includes body["entry"].map { |e| e.dig("resource", "id") }, "1",
          "bare value must match the DFN per FHIR R4 token search"
      end

      # GATE FINDING (Composer, 2026-10-07) -- reproduced before fixing: a bare
      # "00000000001" returned DFN 1, because PatientRepository.find applies
      # `dfn.to_i` and strips the padding. A padded value is a business
      # identifier, not a DFN, and must never resolve one positionally.
      test "padded numeric bare identifier is not coerced into a DFN" do
        get "/lakeraven-ehr/Patient", params: { identifier: "00000000001" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        patient_ids = Array(body["entry"]).map { |e| e.dig("resource", "id") }
        refute_includes patient_ids, "1",
          "a zero-padded value must not resolve DFN 1 through to_i coercion"
        assert_equal 0, body["total"],
          "a padded value matches only as a literal business identifier"
      end

      # Catches String#to_i coercing a dashed SSN into a DFN lookup -- bare
      # "111-11-1111" must not resolve DFN 111.
      test "bare dashed SSN is not coerced into a DFN lookup" do
        get "/lakeraven-ehr/Patient", params: { identifier: "111-11-1111" }, headers: @headers
        assert_response :ok
        patient_ids = JSON.parse(response.body)["entry"].map { |e| e.dig("resource", "id") }
        refute_includes patient_ids, "111",
          "a non-numeric bare value must not be coerced into a DFN"
      end

      # Ensures the foreign fixture is reachable before asserting org isolation.
      test "internal credential resolves foreign patient by DFN system|value" do
        token = "#{DFN_SYSTEM}|#{FOREIGN_DFN}"
        get "/lakeraven-ehr/Patient", params: { identifier: token }, headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_operator body["total"].to_i, :>=, 1
        assert_includes body["entry"].map { |e| e.dig("resource", "id") }, FOREIGN_DFN
      end

      # Catches identifier search bypassing organization_scope filtering (cross-tenant leak).
      test "org-bound credential cannot resolve a foreign organization's patient by identifier" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/Patient.read", organization_id: "rpms-organization-7819")

        foreign_token = "#{DFN_SYSTEM}|#{FOREIGN_DFN}"
        get "/lakeraven-ehr/Patient", params: { identifier: foreign_token }, headers: @headers
        assert_response :ok
        search_body = JSON.parse(response.body)
        assert_equal 0, search_body["total"],
          "foreign patient must not appear in org-filtered identifier search"

        get "/lakeraven-ehr/Patient/#{FOREIGN_DFN}", headers: @headers
        assert_response :forbidden
        show_body = JSON.parse(response.body)
        assert_equal "forbidden", show_body["issue"].first["code"],
          "identifier search refusal must match direct read refusal for foreign patients"
      end

      private

      def seed_foreign_patient!
        client = RpmsRpc.client
        client.seed(:patient_select, FOREIGN_DFN, {
          name: "FOREIGN,PATIENT", sex: "F", dob: Date.parse("1970-01-01"),
          ssn: "999-99-9999", age: 56
        })
        client.seed(:patient_id_info, FOREIGN_DFN, {
          ssn: "999-99-9999", dob: Date.parse("1970-01-01"), sex: "F",
          race_code: "I", site_ien: FOREIGN_SITE_IEN, name: "FOREIGN,PATIENT"
        })
      end
    end
  end
end
