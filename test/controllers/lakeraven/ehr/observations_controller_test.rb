# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ObservationsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_internal_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Observation?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/Observation", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        body["entry"]&.each do |entry|
          assert_equal "Observation", entry.dig("resource", "resourceType")
        end
      end

      # Guards review BLOCKER (same class as the AllergyIntolerance one):
      # supplemental resources are re-checked against the requested patient
      # — a supplemental observation owned by another patient must never be
      # disclosed inside this patient's bundle.
      test "a supplemental observation owned by another patient is never disclosed" do
        Lakeraven::EHR.configuration.supplemental_observations_provider = ->(_dfn) {
          [ Observation.new(
            ien: "lab-999999-hba1c", patient_dfn: "999999", code: "4548-4",
            code_system: "loinc", display: "Hemoglobin A1c", value_quantity: "9.9",
            unit: "%", category: "laboratory", status: "final",
            effective_datetime: DateTime.new(2026, 1, 15, 8, 0, 0)
          ) ]
        }

        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        subjects = Array(body["entry"]).map { |e| e.dig("resource", "subject", "reference") }.compact
        refute_includes subjects, "Patient/999999"
        ids = Array(body["entry"]).map { |e| e.dig("resource", "id") }
        refute_includes ids, "lab-999999-hba1c"
      ensure
        Lakeraven::EHR.configuration.supplemental_observations_provider = nil
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Observation", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/Observation/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/Observation", params: { patient: "1" }
        assert_response :unauthorized
      end
    end
  end
end
