# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ProceduresControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Procedure?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Procedure", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
      end

      test "search without patient param returns 400" do
        get "/lakeraven-ehr/Procedure", headers: @headers
        assert_response :bad_request
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "entries have correct resourceType" do
        # One V CPT row as RpmsRpc::Procedure.for_patient returns it: the
        # visit date, and no status (V CPT has none; rpms-rpc #375).
        RpmsStandIn.answer(RpmsRpc::Procedure, :for_patient, 1, with: [
          { ien: "7001", visit_ien: "2090061", date: Date.new(2026, 3, 10), cpt_code: "99213",
            name: "Office visit, established", provider: "MARTINEZ,SARAH" }
        ])

        get "/lakeraven-ehr/Procedure", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        entries = body["entry"]
        assert entries.is_a?(Array) && entries.any?, "Procedure bundle should include entries"
        entries.each do |entry|
          assert_equal "Procedure", entry.dig("resource", "resourceType")
        end
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Procedure", params: { patient: "1" }, headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "accepts Patient/ prefix in patient param" do
        get "/lakeraven-ehr/Procedure", params: { patient: "Patient/1" }, headers: @headers
        assert_response :ok
      end

      test "requires auth" do
        get "/lakeraven-ehr/Procedure", params: { patient: "1" }
        assert_response :unauthorized
      end
    end
  end
end
