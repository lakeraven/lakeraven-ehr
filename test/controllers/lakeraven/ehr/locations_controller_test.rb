# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class LocationsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Location/:ien returns FHIR Location" do
        get "/lakeraven-ehr/Location/1", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Location", body["resourceType"]
        assert_equal "1", body["id"]
        assert_equal "Primary Care Clinic", body["name"]
      end

      test "unknown Location returns 404" do
        get "/lakeraven-ehr/Location/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "returns FHIR JSON content type" do
        get "/lakeraven-ehr/Location/1", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      test "requires auth" do
        get "/lakeraven-ehr/Location/1"
        assert_response :unauthorized
      end
    end
  end
end
