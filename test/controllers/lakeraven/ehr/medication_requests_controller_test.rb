# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MedicationRequestsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /MedicationRequest?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/MedicationRequest", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        RpmsRpc.client.seed_text(:medication_active, "1", <<~WIRE)
          ~OP^1R;O^LISINOPRIL 10MG TAB^^3271231^3^^^120001^ACTIVE
          \\ Sig: TAKE 1 TABLET BY MOUTH DAILY
        WIRE

        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        entries = body["entry"]
        assert entries.is_a?(Array) && entries.any?, "MedicationRequest bundle should include entries"
        entries.each do |entry|
          assert_equal "MedicationRequest", entry.dig("resource", "resourceType")
        end
      end

      # Lisinopril was discontinued early: its stop date is still in the
      # future, and it is stopped all the same (#628).
      def seed_three_orders
        future = RpmsRpc::FilemanDateParser.format_date(Date.current + 365)
        RpmsRpc.client.seed_text(:medication_active, "1", <<~WIRE)
          ~OP^1R;O^METFORMIN 500MG TAB^^3271231^3^^^120001^ACTIVE
          \\ Sig: TAKE 1 TABLET BY MOUTH TWICE A DAY
          ~OP^2R;O^LISINOPRIL 10MG TAB^^#{future}^2^^^120002^DISCONTINUED
          \\ Sig: TAKE 1 TABLET BY MOUTH DAILY
          ~OP^3R;O^WARFARIN 5MG TAB^^3271231^0^^^120003^HOLD
          \\ Sig: TAKE 1 TABLET BY MOUTH DAILY
        WIRE
      end

      def statuses_by_id(params)
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }.merge(params), headers: @headers
        assert_response :ok
        JSON.parse(response.body)["entry"].to_a.to_h { |e| [ e.dig("resource", "id"), e.dig("resource", "status") ] }
      end

      test "entries carry the status mapped from the RPMS order status" do
        seed_three_orders

        assert_equal({ "1R-O" => "active", "2R-O" => "stopped", "3R-O" => "on-hold" }, statuses_by_id({}))
      end

      test "status search returns only the matching orders" do
        seed_three_orders

        assert_equal({ "1R-O" => "active" }, statuses_by_id(status: "active"))
        assert_equal({ "2R-O" => "stopped" }, statuses_by_id(status: "stopped"))
        assert_equal({}, statuses_by_id(status: "completed"))
      end

      test "status search with several codes matches any of them" do
        seed_three_orders

        assert_equal({ "2R-O" => "stopped", "3R-O" => "on-hold" }, statuses_by_id(status: "stopped,on-hold"))
      end

      test "status search refuses a system|code value with a 400" do
        seed_three_orders

        get "/lakeraven-ehr/MedicationRequest",
          params: { patient: "1", status: "http://hl7.org/fhir/CodeSystem/medicationrequest-status|active" },
          headers: @headers

        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_includes body.dig("issue", 0, "diagnostics"), "status"
      end

      test "status search refuses an empty value with a 400" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1", status: "" }, headers: @headers
        assert_response :bad_request
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "show returns 404 OperationOutcome" do
        get "/lakeraven-ehr/MedicationRequest/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }
        assert_response :unauthorized
      end
    end
  end
end
