# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MeasuresControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Measure returns 200 with FHIR Bundle" do
        get "/lakeraven-ehr/Measure", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "GET /Measure returns FHIR content type" do
        get "/lakeraven-ehr/Measure", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "GET /Measure requires auth" do
        get "/lakeraven-ehr/Measure"
        assert_response :unauthorized
      end

      test "POST /Measure/$import requires auth" do
        post "/lakeraven-ehr/Measure/$import",
          params: { resourceType: "Measure" }.to_json,
          headers: { "Content-Type" => "application/fhir+json" }
        assert_response :unauthorized
      end

      test "POST /Measure/$import with read-only scope returns 403" do
        post "/lakeraven-ehr/Measure/$import",
          params: { resourceType: "Measure" }.to_json,
          headers: @headers.merge("Content-Type" => "application/fhir+json")
        assert_response :forbidden
      end

      test "POST /Measure/$import with write scope and invalid JSON returns 400" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/*.write system/*.read")
        post "/lakeraven-ehr/Measure/$import",
          params: "not json",
          headers: @headers.merge("Content-Type" => "application/fhir+json")
        assert_response :bad_request
      end

      test "POST /Measure/$import with write scope returns valid response" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/Measure.write system/Measure.read")
        post "/lakeraven-ehr/Measure/$import",
          params: { resourceType: "Measure", name: "test-measure", status: "active" }.to_json,
          headers: @headers.merge("Content-Type" => "application/fhir+json")
        # Either success or validation error — not auth error
        assert_includes [ 200, 422 ], response.status
      end

      test "expired token returns 401 on GET /Measure" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        get "/lakeraven-ehr/Measure",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "GET /Measure Bundle includes total" do
        get "/lakeraven-ehr/Measure", headers: @headers
        body = JSON.parse(response.body)
        assert body.key?("total") || body.key?("entry"), "Expected total or entry in Bundle"
      end

      test "GET /Measure returns searchset bundle type" do
        get "/lakeraven-ehr/Measure", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "searchset", body["type"]
      end

      test "POST /Measure/$import response is OperationOutcome" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/Measure.write system/Measure.read")
        post "/lakeraven-ehr/Measure/$import",
          params: { resourceType: "Measure", name: "test", status: "active" }.to_json,
          headers: @headers.merge("Content-Type" => "application/fhir+json")
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "401 response on GET /Measure is OperationOutcome" do
        get "/lakeraven-ehr/Measure"
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "403 response on POST /Measure/$import is OperationOutcome" do
        post "/lakeraven-ehr/Measure/$import",
          params: { resourceType: "Measure" }.to_json,
          headers: @headers.merge("Content-Type" => "application/fhir+json")
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "system wildcard write scope allows import" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/*.write system/*.read")
        post "/lakeraven-ehr/Measure/$import",
          params: { resourceType: "Measure", name: "test", status: "active" }.to_json,
          headers: @headers.merge("Content-Type" => "application/fhir+json")
        assert_includes [ 200, 422 ], response.status
      end

      test "system wildcard all scope allows import" do
        teardown_smart_auth
        setup_smart_auth(scopes: "system/*.*")
        post "/lakeraven-ehr/Measure/$import",
          params: { resourceType: "Measure", name: "test", status: "active" }.to_json,
          headers: @headers.merge("Content-Type" => "application/fhir+json")
        assert_includes [ 200, 422 ], response.status
      end
    end
  end
end
