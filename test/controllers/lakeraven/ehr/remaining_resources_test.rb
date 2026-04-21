# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class RemainingResourcesTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
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
