# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ImmunizationsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Immunization?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Immunization", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/Immunization", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        get "/lakeraven-ehr/Immunization", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        body["entry"]&.each do |entry|
          assert_equal "Immunization", entry.dig("resource", "resourceType")
        end
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Immunization", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Immunization", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "requires auth" do
        get "/lakeraven-ehr/Immunization", params: { patient: "1" }
        assert_response :unauthorized
      end

      # Entries should be proper FHIR resources from Immunization#to_fhir,
      # not raw gateway hashes merged into a thin envelope.
      test "entries render as FHIR-conformant Immunization resources" do
        RpmsRpc.client.seed_keyed_collection(:immunization_list, "1", [
          { ien: 7001, vaccine_code: "207", vaccine_display: "COVID-19 Pfizer-BioNTech, mRNA",
            status: "completed", lot_number: "EX1234",
            occurrence_datetime: Time.utc(2026, 1, 15, 10, 0, 0),
            site: "Left deltoid", route: "IM", performer_duz: "301",
            dose_quantity: 0.3, dose_unit: "mL", manufacturer: "Pfizer-BioNTech",
            vfc_eligibility_code: "V04", funding_source: "VFC" }
        ])

        get "/lakeraven-ehr/Immunization", params: { patient: "1" }, headers: @headers
        assert_response :ok

        body = JSON.parse(response.body)
        assert body["entry"].is_a?(Array), "bundle should have entries"
        assert_equal 1, body["entry"].length, "expected one seeded immunization to render"

        resource = body["entry"].first["resource"]

        # FHIR-conformant key names from Immunization#to_fhir
        assert_equal "Immunization", resource["resourceType"]
        assert_equal "completed", resource["status"]
        assert_equal "Patient/1", resource.dig("patient", "reference")
        assert_equal "207", resource.dig("vaccineCode", "coding", 0, "code")
        assert_equal "EX1234", resource["lotNumber"]
        assert_includes resource["occurrenceDateTime"].to_s, "2026-01-15"

        # Raw snake-case wire keys must not leak through into the FHIR envelope
        refute resource.key?("vaccine_code"), "should not leak raw :vaccine_code key"
        refute resource.key?("lot_number"), "should not leak raw :lot_number key"
        refute resource.key?("occurrence_datetime"), "should not leak raw :occurrence_datetime key"
      end
    end
  end
end
