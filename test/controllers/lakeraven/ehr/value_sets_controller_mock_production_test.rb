# frozen_string_literal: true

require "test_helper"
require "support/terminology_unavailable_backend_test_helper"

module Lakeraven
  module EHR
    # TERMINOLOGY_BACKEND=mock in production must not 500 on ValueSet HTTP
    # endpoints; they refuse with not-supported and log a warning. Explicit
    # AdapterFactory.build(:mock) in production still raises ArgumentError.
    class ValueSetsControllerMockProductionTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include TerminologyUnavailableBackendTestHelper

      setup do
        setup_smart_auth
        @original_terminology_backend = ENV["TERMINOLOGY_BACKEND"]
        @original_rails_env = Rails.env
        ENV["TERMINOLOGY_BACKEND"] = "mock"
        Rails.env = "production"
        Terminology::AdapterFactory.reset_registrations!
      end

      teardown do
        teardown_smart_auth
        ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
        Rails.env = @original_rails_env
        Terminology::AdapterFactory.reset_registrations!
      end

      test "GET ValueSet index in production with mock backend returns not-supported not 500" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "GET ValueSet show in production with mock backend returns not-supported not 500" do
        get "/lakeraven-ehr/ValueSet/synthetic-mock-vs", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "GET ValueSet expand in production with mock backend returns not-supported not 500" do
        get "/lakeraven-ehr/ValueSet/synthetic-mock-vs/$expand", headers: @headers
        assert_valueset_terminology_not_supported_response
      end

      test "mock backend in production logs one warning per ValueSet index request" do
        logs = capture_rails_logs do
          get "/lakeraven-ehr/ValueSet", headers: @headers
        end
        assert_valueset_terminology_not_supported_response
        assert_single_backend_warning_logged(logs, "mock")
      end
    end
  end
end
