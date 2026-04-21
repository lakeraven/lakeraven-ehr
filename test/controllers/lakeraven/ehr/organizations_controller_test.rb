# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class OrganizationsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Organization/:ien returns FHIR Organization" do
        get "/lakeraven-ehr/Organization/1", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Organization", body["resourceType"]
        assert_equal "1", body["id"]
        assert_equal "Alaska Native Medical Center", body["name"]
      end

      test "unknown Organization returns 404" do
        get "/lakeraven-ehr/Organization/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
      end

      test "Organization includes address" do
        get "/lakeraven-ehr/Organization/1", headers: @headers
        body = JSON.parse(response.body)
        addr = body["address"]&.first
        assert_equal "Anchorage", addr["city"]
        assert_equal "AK", addr["state"]
      end
    end
  end
end
