# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # ValueSetsController on backends with no registered production adapter.
    #
    # Expand pins HTTP 404 + OperationOutcome code "not-supported" (same shape as
    # FeatureUnavailableRendering): the operation is refused because terminology
    # expansion is not available on this backend, not because the ValueSet id is
    # missing (that would be not-found). Index/show stay unchanged: empty bundle /
    # not-found when list/get raise NotImplementedError (including AdapterNotAvailable).
    class ValueSetsControllerUnavailableBackendTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        setup_smart_auth
        @original_terminology_backend = ENV["TERMINOLOGY_BACKEND"]
        @original_iris = ENV["IRIS_TERMINOLOGY_URL"]
        @original_umls = ENV["UMLS_API_KEY"]
        ENV["TERMINOLOGY_BACKEND"] = nil
        ENV["UMLS_API_KEY"] = nil
        ENV["IRIS_TERMINOLOGY_URL"] = "https://iris.example.com/fhir"
        Terminology::AdapterFactory.reset_registrations!
      end

      teardown do
        teardown_smart_auth
        ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
        ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
        ENV["UMLS_API_KEY"] = @original_umls
        Terminology::AdapterFactory.reset_registrations!
      end

      test "GET ValueSet index on unavailable backend returns empty searchset bundle" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
        assert_equal [], body["entry"]
      end

      test "GET ValueSet show on unavailable backend returns not-found OperationOutcome" do
        get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "GET ValueSet expand on unavailable backend returns not-supported OperationOutcome without 500" do
        get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx/$expand", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-supported", body["issue"].first["code"]
        assert_equal "application/fhir+json", response.media_type
      end
    end
  end
end
