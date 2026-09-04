# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MedicationsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_internal_smart_auth
        MedicationStore.instance.add(
          Medication.new(fhir_id: "med-861007", code: "861007",
                         display: "Metformin hydrochloride 500 MG Oral Tablet")
        )
        MedicationStore.instance.add(
          Medication.new(fhir_id: "med-314076", code: "314076",
                         display: "Lisinopril 10 MG Oral Tablet")
        )
      end

      teardown do
        teardown_smart_auth
        MedicationStore.reset_instance!
      end

      test "GET /Medication returns FHIR Bundle of Medication resources" do
        get "/lakeraven-ehr/Medication", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal 2, body["total"]
        body["entry"].each do |entry|
          assert_equal "Medication", entry.dig("resource", "resourceType")
        end
      end

      test "GET /Medication?code= filters by RxNorm code" do
        get "/lakeraven-ehr/Medication", params: { code: "314076" }, headers: @headers
        body = JSON.parse(response.body)
        assert_equal 1, body["total"]
        assert_equal "med-314076", body["entry"].first.dig("resource", "id")
      end

      test "GET /Medication/{id} returns the RxNorm-coded resource" do
        get "/lakeraven-ehr/Medication/med-861007", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Medication", body["resourceType"]
        coding = body.dig("code", "coding", 0)
        assert_equal "http://www.nlm.nih.gov/research/umls/rxnorm", coding["system"]
        assert_equal "861007", coding["code"]
      end

      test "GET /Medication/{unknown} returns 404 OperationOutcome" do
        get "/lakeraven-ehr/Medication/med-000", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/Medication/med-861007"
        assert_response :unauthorized
      end

      test "readable by an org-bound system credential (no patient compartment)" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/Medication.read")
        get "/lakeraven-ehr/Medication/med-861007", headers: @headers
        assert_response :ok
      end
    end
  end
end
