# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BogusTerminologyBackendTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

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

      test "index with bogus TERMINOLOGY_BACKEND returns empty bundle not 500" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal "searchset", body["type"]
        assert_equal [], body["entry"]
      end

      test "expand with bogus TERMINOLOGY_BACKEND returns not-supported OperationOutcome not 500" do
        get "/lakeraven-ehr/ValueSet/gpra-bgpmu-diabetes-dx/$expand", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-supported", body["issue"].first["code"]
      end
    end
  end
end
