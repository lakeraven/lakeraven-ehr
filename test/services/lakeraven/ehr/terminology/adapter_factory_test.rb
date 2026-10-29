# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module Terminology
      class AdapterFactoryTest < ActiveSupport::TestCase
        setup do
          @original_terminology_backend = ENV["TERMINOLOGY_BACKEND"]
          @original_umls = ENV["UMLS_API_KEY"]
          @original_iris = ENV["IRIS_TERMINOLOGY_URL"]
          ENV["TERMINOLOGY_BACKEND"] = nil
          ENV["UMLS_API_KEY"] = nil
          ENV["IRIS_TERMINOLOGY_URL"] = nil
          AdapterFactory.reset_registrations!
        end

        teardown do
          ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
          ENV["UMLS_API_KEY"] = @original_umls
          ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
          AdapterFactory.reset_registrations!
        end

        test "detects local backend when no env signals are present" do
          adapter = AdapterFactory.build
          assert_equal :local, adapter.backend
          assert_kind_of LocalAdapter, adapter
        end

        test "TERMINOLOGY_BACKEND overrides IRIS and VSAC env detection" do
          ENV["TERMINOLOGY_BACKEND"] = "vsac"
          ENV["IRIS_TERMINOLOGY_URL"] = "https://iris.example.com/fhir"
          ENV["UMLS_API_KEY"] = "test-key"
          adapter = AdapterFactory.build
          assert_equal :vsac, adapter.backend
        end

        test "IRIS env takes precedence over VSAC when TERMINOLOGY_BACKEND is unset" do
          ENV["IRIS_TERMINOLOGY_URL"] = "https://iris.example.com/fhir"
          ENV["UMLS_API_KEY"] = "test-key"
          adapter = AdapterFactory.build
          assert_equal :iris, adapter.backend
        end

        test "VSAC env is selected when only UMLS_API_KEY is set" do
          ENV["UMLS_API_KEY"] = "test-key"
          adapter = AdapterFactory.build
          assert_equal :vsac, adapter.backend
        end

        test "builds MockAdapter for mock backend" do
          adapter = AdapterFactory.build(:mock)
          assert_equal :mock, adapter.backend
          assert_kind_of MockAdapter, adapter
        end

        test "register returns a custom adapter for the registered backend" do
          sentinel = Class.new(BaseAdapter) do
            def backend = :iris
            def expand_valueset(_id) = [ { system: "http://example.com", code: "IRIS-1", display: "From IRIS" } ]
            def get_valueset(_id) = nil
            def list_valuesets = []
            def search(_query) = []
            def lookup_code(_system, _code) = nil
            def validate_code(_system, _code, valueset_id:) = false
          end

          AdapterFactory.register(:iris) { sentinel.new }
          adapter = AdapterFactory.build(:iris)
          assert_equal "IRIS-1", adapter.expand_valueset("any").first[:code]
        end

        test "reset_registrations clears host registrations" do
          AdapterFactory.register(:iris) { LocalAdapter.new }
          AdapterFactory.reset_registrations!
          adapter = AdapterFactory.build(:iris)
          assert_raises(AdapterNotAvailable) { adapter.expand_valueset("any") }
        end

        test "unregistered iris backend builds without error and raises AdapterNotAvailable on use" do
          adapter = AdapterFactory.build(:iris)
          assert_equal :iris, adapter.backend
          error = assert_raises(AdapterNotAvailable) { adapter.expand_valueset("gpra-bgpmu-diabetes-dx") }
          assert_match(/iris/i, error.message)
          assert_match(/no adapter is registered/i, error.message)
        end

        test "unregistered vsac backend builds without error and raises AdapterNotAvailable on use" do
          adapter = AdapterFactory.build(:vsac)
          assert_equal :vsac, adapter.backend
          error = assert_raises(AdapterNotAvailable) { adapter.lookup_code("http://hl7.org/fhir/sid/icd-10-cm", "E11.9") }
          assert_match(/vsac/i, error.message)
          assert_match(/no adapter is registered/i, error.message)
        end

        test "unregistered iris adapter never returns local fixture codes" do
          adapter = AdapterFactory.build(:iris)
          assert_raises(AdapterNotAvailable) { adapter.expand_valueset("gpra-bgpmu-diabetes-dx") }
        end

        test "unknown backend raises ArgumentError listing available backends" do
          error = assert_raises(ArgumentError) { AdapterFactory.build(:nonsense) }
          assert_match(/nonsense/i, error.message)
          assert_match(/local/i, error.message)
          assert_match(/mock/i, error.message)
          assert_match(/iris/i, error.message)
          assert_match(/vsac/i, error.message)
        end

        test "building every documented backend does not raise NameError" do
          %i[local mock iris vsac].each do |backend|
            assert_nothing_raised(NameError) { AdapterFactory.build(backend) }
          end
        end

        test "AdapterNotAvailable is a NotImplementedError subclass" do
          adapter = AdapterFactory.build(:iris)
          error = assert_raises(NotImplementedError) { adapter.list_valuesets }
          assert_kind_of AdapterNotAvailable, error
        end
      end
    end
  end
end
