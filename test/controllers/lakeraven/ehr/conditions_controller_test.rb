# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ConditionsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Condition?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/Condition", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        RpmsRpc.client.seed_keyed_collection(:problem_list, "1", [
          { ien: 1, status: "A", icd_code: "E11.9", description: "Type 2 diabetes mellitus" }
        ])

        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        entries = body["entry"]
        assert entries.is_a?(Array) && entries.any?, "Condition bundle should include entries"
        entries.each do |entry|
          assert_equal "Condition", entry.dig("resource", "resourceType")
        end
      end

      test "a diagnosis on a visit is an encounter-diagnosis naming that visit" do
        RpmsRpc.client.seed_keyed_collection(:encounter_visit_list, "1", [
          { visit_string: "6;3260825.09;A;7", location: "Clinic", category: "AMBULATORY" }
        ])
        RpmsRpc.client.seed_keyed_collection(:patient_pov_list, "1", [
          { ien: "9", visit_ien: "7", visit_date: "08/25/2026", icd_code: "I10.",
            icd_name: "Essential (primary) hypertension", narrative: "HYPERTENSION" }
        ])

        get "/lakeraven-ehr/Condition/1-pov-9", headers: @headers

        assert_response :ok
        diagnosis = JSON.parse(response.body)
        assert_equal "encounter-diagnosis", diagnosis.dig("category", 0, "coding", 0, "code")
        assert_equal "I10", diagnosis.dig("code", "coding", 0, "code")
        assert_equal "Essential (primary) hypertension", diagnosis.dig("code", "text")
        assert_equal "Encounter/1-7", diagnosis.dig("encounter", "reference")
        assert_equal "2026-08-25", diagnosis["recordedDate"]
      end

      test "a diagnosis on a visit the visit list leaves out does not name it" do
        RpmsRpc.client.seed_keyed_collection(:encounter_visit_list, "1", [])
        RpmsRpc.client.seed_keyed_collection(:patient_pov_list, "1", [
          { ien: "9", visit_ien: "4", visit_date: "09/02/2026", icd_code: "E11.9", icd_name: "Diabetes" }
        ])

        get "/lakeraven-ehr/Condition/1-pov-9", headers: @headers

        assert_response :ok
        assert_nil JSON.parse(response.body)["encounter"]
      end

      test "a search keeps problems and visit diagnoses apart by category" do
        RpmsRpc.client.seed_keyed_collection(:problem_list, "1", [ { ien: 1, status: "A", icd_code: "E11.9", description: "Diabetes" } ])
        RpmsRpc.client.seed_keyed_collection(:patient_pov_list, "1", [
          { ien: "9", visit_ien: "7", visit_date: "08/25/2026", icd_code: "E11.9", icd_name: "Diabetes" }
        ])

        { "problem-list-item" => %w[1-1], "encounter-diagnosis" => %w[1-pov-9] }.each do |category, ids|
          get "/lakeraven-ehr/Condition", params: { patient: "1", category: category }, headers: @headers
          assert_equal ids, JSON.parse(response.body)["entry"].map { |entry| entry.dig("resource", "id") }, category
        end
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Condition", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/Condition/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }
        assert_response :unauthorized
      end
    end
  end
end
