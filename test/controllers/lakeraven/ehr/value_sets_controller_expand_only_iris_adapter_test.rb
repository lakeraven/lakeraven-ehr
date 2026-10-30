# frozen_string_literal: true

require "test_helper"
require "support/terminology_unavailable_backend_test_helper"

module Lakeraven
  module EHR
    # Registered :iris adapter that implements only expand_valueset (BaseAdapter
    # defaults for list/get). Index and show must refuse with not-supported, not
    # an empty searchset or a not-found outcome; $expand still returns codes.
    class ValueSetsControllerExpandOnlyIrisAdapterTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include TerminologyUnavailableBackendTestHelper

      EXPAND_ONLY_IRIS = Class.new(Terminology::BaseAdapter) do
        def backend = :iris

        def expand_valueset(_id)
          [ { system: "http://iris.example.com/synthetic", code: "IRIS-EXPAND-ONLY", display: "Synthetic" } ]
        end
      end

      setup do
        setup_smart_auth
        @original_terminology_backend = ENV["TERMINOLOGY_BACKEND"]
        @original_iris = ENV["IRIS_TERMINOLOGY_URL"]
        @original_umls = ENV["UMLS_API_KEY"]
        ENV["UMLS_API_KEY"] = nil
        ENV["IRIS_TERMINOLOGY_URL"] = nil
        ENV["TERMINOLOGY_BACKEND"] = "iris"
        Terminology::AdapterFactory.reset_registrations!
        Terminology::AdapterFactory.register(:iris) { EXPAND_ONLY_IRIS.new }
      end

      teardown do
        teardown_smart_auth
        ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
        ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
        ENV["UMLS_API_KEY"] = @original_umls
        Terminology::AdapterFactory.reset_registrations!
      end

      test "GET ValueSet index with expand-only iris adapter returns not-supported not empty searchset" do
        get "/lakeraven-ehr/ValueSet", headers: @headers
        assert_valueset_terminology_not_supported_response
        body = JSON.parse(response.body)
        refute_equal "Bundle", body["resourceType"],
                     "Index must not answer an empty searchset when list_valuesets is unimplemented"
      end

      test "GET ValueSet show with expand-only iris adapter returns not-supported not not-found" do
        get "/lakeraven-ehr/ValueSet/synthetic-vs-id", headers: @headers
        assert_valueset_terminology_not_supported_response
        body = JSON.parse(response.body)
        refute_equal "not-found", body["issue"].first["code"],
                     "Show must not map unimplemented get_valueset to not-found"
      end

      test "GET ValueSet expand with expand-only iris adapter still serves expansion codes" do
        get "/lakeraven-ehr/ValueSet/synthetic-vs-id/$expand", headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "ValueSet", body["resourceType"]
        assert_equal "IRIS-EXPAND-ONLY", body.dig("expansion", "contains", 0, "code")
      end
    end
  end
end
