# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # GATE SPEC — ORHC Booth Demo Spec v1.1 §5 (Patient.identifier) and §8.2.
    # HTTP entry point only; org-bound credential matches sandbox site 5001.
    class PatientMrnIdentifierSearchTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include OrhcDemoSeedHelper

      ORHC_MRN_SYSTEM = "http://example.org/fhir/sid/orhc-demo/mrn"
      DFN_SYSTEM = "urn:oid:2.16.840.1.113883.4.349"
      SITE_IEN = 5001
      PAT_A_DFN = "9101"
      PAT_B_DFN = "9102"

      setup do
        setup_smart_auth(scopes: "system/Patient.read", organization_id: "rpms-organization-#{SITE_IEN}")
        seed_orhc_demo_patients!
      end

      teardown do
        teardown_smart_auth
        restore_default_rpms_patient_seeds!
      end

      # Catches identifier_search that still discards the system and searches SSN only.
      test "ORHC-A resolves by fixture MRN system|value with exactly one match" do
        get "/lakeraven-ehr/Patient",
          params: { identifier: "#{ORHC_MRN_SYSTEM}|ORHC-A" },
          headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal 1, body["total"],
          "must not return an unfiltered patient list for a business identifier lookup"
        assert_equal PAT_A_DFN, body.dig("entry", 0, "resource", "id")
        assert_equal "match", body.dig("entry", 0, "search", "mode")
      end

      # Catches seeding only patient A or conflating the two MRNs.
      test "ORHC-B resolves by fixture MRN system|value with exactly one match" do
        get "/lakeraven-ehr/Patient",
          params: { identifier: "#{ORHC_MRN_SYSTEM}|ORHC-B" },
          headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal 1, body["total"]
        assert_equal PAT_B_DFN, body.dig("entry", 0, "resource", "id")
      end

      # Catches returning searchset id that does not match GET /Patient/{id}.
      test "MRN searchset id resolves on direct read" do
        get "/lakeraven-ehr/Patient",
          params: { identifier: "#{ORHC_MRN_SYSTEM}|ORHC-A" },
          headers: @headers
        pid = JSON.parse(response.body).dig("entry", 0, "resource", "id")
        refute_nil pid

        get "/lakeraven-ehr/Patient/#{pid}", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Patient", body["resourceType"]
        assert_equal pid, body["id"]
        assert_equal "Kessler", body.dig("name", 0, "family")
        assert_equal "Pat", body.dig("name", 0, "given", 0)
      end

      # Catches silent empty Bundle (false negative) on unknown identifier systems.
      test "unrecognised identifier system returns 400 OperationOutcome not-supported" do
        get "/lakeraven-ehr/Patient",
          params: { identifier: "http://example.com/unknown-identifier-system|ORHC-A" },
          headers: @headers

        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-supported", body["issue"].first["code"],
          "unknown systems must not widen into an unfiltered Patient search"
      end

      # ORHC §5 + patient_identifier_search_test: bare value is not DFN lookup (SSN legacy only).
      # Catches widening identifier_search to match DFN digits when system is absent.
      test "bare identifier value without system does not resolve by DFN" do
        get "/lakeraven-ehr/Patient", params: { identifier: PAT_A_DFN }, headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        patient_ids = Array(body["entry"]).map { |e| e.dig("resource", "id") }
        refute_includes patient_ids, PAT_A_DFN,
          "bare DFN must not match without an explicit identifier system"
      end

      # Catches identifier search bypassing organization_scope (cross-tenant leak).
      test "org-bound credential cannot resolve another site's patient by ORHC MRN" do
        foreign_token = "#{ORHC_MRN_SYSTEM}|ORHC-FOREIGN"
        get "/lakeraven-ehr/Patient", params: { identifier: foreign_token }, headers: @headers
        assert_response :ok
        search_body = JSON.parse(response.body)
        assert_equal "Bundle", search_body["resourceType"]
        entries = Array(search_body["entry"])
        patient_ids = entries.map { |e| e.dig("resource", "id") }
        refute_includes patient_ids, "9007",
          "foreign-site patient must not appear in org-filtered identifier search"
        refute entries.any? { |e|
          Array(e.dig("resource", "identifier")).any? { |id|
            id["system"] == ORHC_MRN_SYSTEM && id["value"] == "ORHC-FOREIGN"
          }
        }, "foreign ORHC MRN must not resolve under another organisation's credential"

        get "/lakeraven-ehr/Patient/9007", headers: @headers
        assert_response :forbidden
      end

    end
  end
end
