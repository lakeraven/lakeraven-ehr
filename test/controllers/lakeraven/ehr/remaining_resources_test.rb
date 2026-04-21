# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class RemainingResourcesTest < ActionDispatch::IntegrationTest
      setup do
        @oauth_app = Doorkeeper::Application.create!(
          name: "test", redirect_uri: "https://example.test/callback",
          scopes: "system/*.read", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: 3600
        )
        @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      teardown do
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      # -- ServiceRequest ------------------------------------------------------

      test "GET /ServiceRequest?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "ServiceRequest search without patient returns 400" do
        get "/lakeraven-ehr/ServiceRequest", headers: @headers
        assert_response :bad_request
      end

      # -- Immunization --------------------------------------------------------

      test "GET /Immunization?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Immunization", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "Immunization search without patient returns 400" do
        get "/lakeraven-ehr/Immunization", headers: @headers
        assert_response :bad_request
      end

      # -- Procedure -----------------------------------------------------------

      test "GET /Procedure?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Procedure", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "Procedure search without patient returns 400" do
        get "/lakeraven-ehr/Procedure", headers: @headers
        assert_response :bad_request
      end
    end
  end
end
