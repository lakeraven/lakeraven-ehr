# frozen_string_literal: true

require "test_helper"
require "support/terminology_unavailable_backend_test_helper"

module Lakeraven
  module EHR
    # ValueSetsController on backends with no registered production adapter.
    #
    # Index, show, and $expand all refuse with the same not-supported OperationOutcome
    # (HTTP 404, fixed diagnostics that name neither backend nor adapter class).
    # A warning naming the backend is logged once per request.
    class ValueSetsControllerUnavailableBackendTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include TerminologyUnavailableBackendTestHelper

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

      test "GET ValueSet index on unavailable backend returns not-supported OperationOutcome" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "GET ValueSet show on unavailable backend returns not-supported OperationOutcome" do
        get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "GET ValueSet expand on unavailable backend returns not-supported OperationOutcome without 500" do
        get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx/$expand", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "unavailable backend logs one warning naming iris per ValueSet index request" do
        logs = capture_rails_logs do
          get "/lakeraven-ehr/ValueSet", headers: @headers
        end
        assert_valueset_terminology_not_supported_response
        assert_single_backend_warning_logged(logs, "iris")
      end

      test "unavailable backend logs one warning naming iris per ValueSet show request" do
        logs = capture_rails_logs do
          get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx", headers: @headers
        end
        assert_valueset_terminology_not_supported_response
        assert_single_backend_warning_logged(logs, "iris")
      end
    end
  end
end
