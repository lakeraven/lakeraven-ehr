# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class DiagnosticReportsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_internal_smart_auth
        DiagnosticReportStore.instance.add(DiagnosticReport.new(
          ien: "80011", patient_dfn: "1", category: "LAB",
          code: "4548-4", code_display: "Hemoglobin A1c", status: "final",
          effective_datetime: DateTime.new(2026, 8, 12, 8, 0, 0),
          issued: DateTime.new(2026, 8, 12, 15, 0, 0),
          performer_duz: "101", performer_name: "MARTINEZ,SARAH",
          result_iens: "lab-1-hba1c", conclusion: "Above goal"
        ))
        DiagnosticReportStore.instance.add(DiagnosticReport.new(
          ien: "80012", patient_dfn: "1", category: "LAB",
          code: "13457-7", code_display: "Lipid panel", status: "final",
          effective_datetime: DateTime.new(2026, 2, 10, 8, 0, 0),
          issued: DateTime.new(2026, 2, 10, 15, 0, 0),
          performer_duz: "101", performer_name: "MARTINEZ,SARAH",
          result_iens: "lab-1-ldl"
        ))
        # A foreign-organization patient's report: dfn 999999 resolves to no
        # patient the test org (rpms-organization-7819) manages.
        DiagnosticReportStore.instance.add(DiagnosticReport.new(
          ien: "80091", patient_dfn: "999999", category: "LAB",
          code: "4548-4", code_display: "Hemoglobin A1c", status: "final"
        ))
      end

      teardown do
        teardown_smart_auth
        DiagnosticReportStore.reset_instance!
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

      # Guards review finding: a blank/unrecognized source status was
      # promoted to "final" pre-fix. It must serve as "unknown".
      test "a report with a blank status serves as unknown, never final" do
        DiagnosticReportStore.instance.add(DiagnosticReport.new(
          ien: "80013", patient_dfn: "1", category: "LAB",
          code: "58410-2", code_display: "CBC"
        ))
        get "/lakeraven-ehr/DiagnosticReport", params: { patient: "1" }, headers: @headers
        report = JSON.parse(response.body)["entry"]
          .map { |e| e["resource"] }.find { |r| r["id"] == "80013" }
        assert_equal "unknown", report["status"]
      end

      # Guards review finding: DiagnosticReport.code is 1..1 — a report with
      # no source naming must be OMITTED, not emitted codeless.
      test "a report without any code is omitted rather than served invalid" do
        DiagnosticReportStore.instance.add(DiagnosticReport.new(
          ien: "80014", patient_dfn: "1", category: "LAB", status: "final"
        ))
        get "/lakeraven-ehr/DiagnosticReport", params: { patient: "1" }, headers: @headers
        body = JSON.parse(response.body)
        ids = body["entry"].map { |e| e.dig("resource", "id") }
        refute_includes ids, "80014"
        body["entry"].each do |entry|
          assert entry.dig("resource", "code").present?, "every served DiagnosticReport must carry a code"
        end

        get "/lakeraven-ehr/DiagnosticReport/80014", headers: @headers
        assert_response :not_found
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

      # Guards review finding: search emitted ids that show could not
      # resolve. Every id a search returns must be readable.
      test "every id returned by search is readable via show" do
        get "/lakeraven-ehr/DiagnosticReport", params: { patient: "1" }, headers: @headers
        ids = JSON.parse(response.body)["entry"].map { |e| e.dig("resource", "id") }
        assert ids.any?

        ids.each do |id|
          get "/lakeraven-ehr/DiagnosticReport/#{id}", headers: @headers
          assert_response :ok
          body = JSON.parse(response.body)
          assert_equal "DiagnosticReport", body["resourceType"]
          assert_equal id, body["id"]
        end
      end

      test "show returns 404 OperationOutcome for an unknown id" do
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

      # Guards review finding: a resolved foreign resource must be a 403
      # (never served, never a masking 404).
      test "org-bound credential gets 403 for a foreign patient's report id" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/DiagnosticReport.read")

        get "/lakeraven-ehr/DiagnosticReport/80011", headers: @headers
        assert_response :ok

        get "/lakeraven-ehr/DiagnosticReport/80091", headers: @headers
        assert_response :forbidden
      end
    end
  end
end
