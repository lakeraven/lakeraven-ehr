# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Patient/:dfn returns 200 with FHIR Patient" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        assert_response :ok
        assert_equal "application/fhir+json", response.media_type
        body = JSON.parse(response.body)
        assert_equal "Patient", body["resourceType"]
        assert_equal "1", body["id"]
      end

      test "response includes US Core profile" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_includes body.dig("meta", "profile"),
                        "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
      end

      test "response includes name family and given" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "Anderson", body["name"].first["family"]
        assert_includes body["name"].first["given"], "Alice"
      end

      test "response includes gender and birthDate" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "female", body["gender"]
        assert_equal "1980-05-15", body["birthDate"]
      end

      test "response includes SSN identifier" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        ssn_id = body["identifier"].find { |id| id["system"]&.include?("ssn") }
        assert_equal "111-11-1111", ssn_id["value"]
      end

      test "unknown DFN returns 404 OperationOutcome" do
        get "/lakeraven-ehr/Patient/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "GET /Patient searches by name" do
        get "/lakeraven-ehr/Patient", params: { name: "Anderson" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_operator body["total"], :>=, 1
      end

      test "GET /Patient with no matches returns empty Bundle" do
        get "/lakeraven-ehr/Patient", params: { name: "ZZZZNONEXISTENT" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal 0, body["total"]
      end
    end
  end
end
