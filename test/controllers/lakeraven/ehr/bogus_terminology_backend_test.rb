# frozen_string_literal: true

require "test_helper"
require "support/terminology_unavailable_backend_test_helper"

module Lakeraven
  module EHR
    class BogusTerminologyBackendTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include TerminologyUnavailableBackendTestHelper

      setup do
        setup_smart_auth
        @original_terminology_backend = ENV["TERMINOLOGY_BACKEND"]
        @original_iris = ENV["IRIS_TERMINOLOGY_URL"]
        @original_umls = ENV["UMLS_API_KEY"]
        ENV["UMLS_API_KEY"] = nil
        ENV["IRIS_TERMINOLOGY_URL"] = nil
        ENV["TERMINOLOGY_BACKEND"] = "bogus"
        Terminology::AdapterFactory.reset_registrations!
      end

      teardown do
        teardown_smart_auth
        ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
        ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
        ENV["UMLS_API_KEY"] = @original_umls
        Terminology::AdapterFactory.reset_registrations!
      end

      test "index with bogus TERMINOLOGY_BACKEND returns not-supported OperationOutcome not 500" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "show with bogus TERMINOLOGY_BACKEND returns not-supported OperationOutcome not 500" do
        get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "expand with bogus TERMINOLOGY_BACKEND returns not-supported OperationOutcome not 500" do
        get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx/$expand", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "typo TERMINOLOGY_BACKEND locla returns not-supported on index and show" do
        ENV["TERMINOLOGY_BACKEND"] = "locla"
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_valueset_terminology_not_supported_response

        get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "bogus backend logs one warning naming the backend per index request" do
        logs = capture_rails_logs do
          get "/lakeraven-ehr/ValueSet", headers: @headers
        end
        assert_valueset_terminology_not_supported_response
        assert_single_backend_warning_logged(logs, "bogus")
      end
    end
  end
end
