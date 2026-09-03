# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DiagnosticReportsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_internal_smart_auth
        RpmsRpc.client.seed_keyed_collection(:lab_report_list, "1", [
          { ien: 80011, report_name: "Hemoglobin A1c", loinc_code: "4548-4",
            status: "final", collection_date: DateTime.new(2026, 8, 12, 8, 0, 0),
            result_date: DateTime.new(2026, 8, 12, 15, 0, 0),
            verifier_duz: "101", verifier_name: "MARTINEZ,SARAH",
            result_iens: "lab-1-hba1c", interpretation: "Above goal" },
          { ien: 80012, report_name: "Lipid panel", loinc_code: "13457-7",
            status: "final", collection_date: DateTime.new(2026, 2, 10, 8, 0, 0),
            result_date: DateTime.new(2026, 2, 10, 15, 0, 0),
            verifier_duz: "101", verifier_name: "MARTINEZ,SARAH",
            result_iens: "lab-1-ldl", interpretation: "" }
        ])
      end

      teardown do
        teardown_smart_auth
        RpmsRpc.client.seed_keyed_collection(:lab_report_list, "1", [])
      end

      test "GET /DiagnosticReport?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/DiagnosticReport", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal 2, body["total"]
        body["entry"].each do |entry|
          assert_equal "DiagnosticReport", entry.dig("resource", "resourceType")
        end
      end

      test "reports carry code, result references, effectiveDateTime, conclusion" do
        get "/lakeraven-ehr/DiagnosticReport", params: { patient: "1" }, headers: @headers
        report = JSON.parse(response.body)["entry"]
          .map { |e| e["resource"] }.find { |r| r["id"] == "80011" }
        assert_equal "4548-4", report.dig("code", "coding", 0, "code")
        assert_equal "http://loinc.org", report.dig("code", "coding", 0, "system")
        assert_equal [ { "reference" => "Observation/lab-1-hba1c" } ], report["result"]
        assert report["effectiveDateTime"].start_with?("2026-08-12")
        assert_equal "Above goal", report["conclusion"]
      end

      test "date=ge filters on effectiveDateTime" do
        get "/lakeraven-ehr/DiagnosticReport",
          params: { patient: "1", date: "ge2026-08-01" }, headers: @headers
        body = JSON.parse(response.body)
        assert_equal 1, body["total"]
        assert_equal "80011", body["entry"].first.dig("resource", "id")
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/DiagnosticReport", headers: @headers
        assert_response :bad_request
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/DiagnosticReport/99999", headers: @headers
        assert_response :not_found
      end

      test "requires auth" do
        get "/lakeraven-ehr/DiagnosticReport", params: { patient: "1" }
        assert_response :unauthorized
      end

      test "org-bound system credential reads its own organization's patient" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/DiagnosticReport.read")
        get "/lakeraven-ehr/DiagnosticReport", params: { patient: "1" }, headers: @headers
        assert_response :ok
      end
    end
  end
end
