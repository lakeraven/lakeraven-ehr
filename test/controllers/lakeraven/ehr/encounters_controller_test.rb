# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EncountersControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Encounter?patient=1 returns FHIR Bundle" do
        get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
      end

      test "Encounter search without patient returns 400" do
        get "/lakeraven-ehr/Encounter", headers: @headers
        assert_response :bad_request
      end
    end
  end
end
