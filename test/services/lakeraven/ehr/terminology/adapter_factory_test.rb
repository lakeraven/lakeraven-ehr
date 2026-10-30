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
          @original_rails_env = Rails.env
          ENV["TERMINOLOGY_BACKEND"] = nil
          ENV["UMLS_API_KEY"] = nil
          ENV["IRIS_TERMINOLOGY_URL"] = nil
          AdapterFactory.reset_registrations!
        end

        teardown do
          ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
          ENV["UMLS_API_KEY"] = @original_umls
          ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
          Rails.env = @original_rails_env
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

        test "explicit unknown backend argument raises ArgumentError listing available backends" do
          error = assert_raises(ArgumentError) { AdapterFactory.build(:nonsense) }
          assert_match(/nonsense/i, error.message)
          assert_match(/local/i, error.message)
          assert_match(/mock/i, error.message)
          assert_match(/iris/i, error.message)
          assert_match(/vsac/i, error.message)
        end

        test "TERMINOLOGY_BACKEND is stripped and downcased" do
          ENV["TERMINOLOGY_BACKEND"] = " LOCAL "
          adapter = AdapterFactory.build
          assert_kind_of LocalAdapter, adapter
          assert_equal :local, adapter.backend

          ENV["TERMINOLOGY_BACKEND"] = "Iris"
          adapter = AdapterFactory.build
          assert_equal :iris, adapter.backend
          assert_raises(AdapterNotAvailable) { adapter.expand_valueset("any") }
        end

        test "configured unknown TERMINOLOGY_BACKEND builds an unavailable adapter" do
          ENV["TERMINOLOGY_BACKEND"] = "bogus"
          adapter = AdapterFactory.build
          assert_equal :bogus, adapter.backend
          error = assert_raises(AdapterNotAvailable) { adapter.list_valuesets }
          assert_match(/bogus/i, error.message)
        end

        test "TERMINOLOGY_BACKEND mock in production builds without ArgumentError explicit build still refused" do
          Rails.env = "production"
          ENV["TERMINOLOGY_BACKEND"] = "mock"
          adapter = assert_nothing_raised { AdapterFactory.build }
          assert_equal :mock, adapter.backend

          error = assert_raises(ArgumentError) { AdapterFactory.build(:mock) }
          assert_match(/production/i, error.message)
        end

        test "build rejects registration that returns bare BaseAdapter without implemented backend" do
          AdapterFactory.register(:iris) { BaseAdapter.new }
          error = assert_raises(ArgumentError) { AdapterFactory.build(:iris) }
          assert_match(/iris/i, error.message)
          refute_kind_of NotImplementedError, error.class
        end

        test "mock backend builds in test and development" do
          Rails.env = "test"
          assert_kind_of MockAdapter, AdapterFactory.build(:mock)

          Rails.env = "development"
          assert_kind_of MockAdapter, AdapterFactory.build(:mock)
        end

        test "register without a block raises ArgumentError at registration time" do
          assert_raises(ArgumentError) { AdapterFactory.register(:iris) }
        end

        test "build rejects a registration that does not return a BaseAdapter" do
          AdapterFactory.register(:iris) { Object.new }
          assert_raises(ArgumentError) { AdapterFactory.build(:iris) }

          AdapterFactory.reset_registrations!
          AdapterFactory.register(:iris) { "not-an-adapter" }
          assert_raises(ArgumentError) { AdapterFactory.build(:iris) }

          AdapterFactory.reset_registrations!
          AdapterFactory.register(:iris) { LocalAdapter }
          assert_raises(ArgumentError) { AdapterFactory.build(:iris) }
        end

        test "build rejects a registration whose adapter backend differs from the registered name" do
          AdapterFactory.register(:iris) { LocalAdapter.new }
          error = assert_raises(ArgumentError) { AdapterFactory.build(:iris) }
          assert_match(/iris/i, error.message)
          assert_match(/local/i, error.message)
        end

        BASE_ADAPTER_INTERFACE = %i[
          expand_valueset get_valueset list_valuesets search lookup_code validate_code backend
        ].freeze

        test "building every documented backend does not raise NameError" do
          %i[local mock iris vsac].each do |backend|
            assert_nothing_raised do
              adapter = AdapterFactory.build(backend)
              assert_kind_of BaseAdapter, adapter
              BASE_ADAPTER_INTERFACE.each { |method| assert_respond_to adapter, method }
              assert_equal backend, adapter.backend
            end
          end
        end

        test "AdapterNotAvailable is a StandardError caught by rescue => e" do
          adapter = AdapterFactory.build(:iris)
          caught_by_standard_rescue = false
          begin
            begin
              adapter.list_valuesets
            rescue StandardError
              caught_by_standard_rescue = true
            end
          rescue NotImplementedError
            caught_by_standard_rescue = false
          end
          assert caught_by_standard_rescue,
                 "AdapterNotAvailable must inherit StandardError so bare rescue => e catches it"
          refute AdapterNotAvailable <= NotImplementedError
        end

        test "backend names are normalized for build register and TerminologyService" do
          iris_sentinel = Class.new(BaseAdapter) do
            def backend = :iris

            def expand_valueset(_id)
              [ { system: "http://example.com", code: "IRIS-NORM", display: "From registered IRIS" } ]
            end

            def get_valueset(_id) = nil
            def list_valuesets = []
            def search(_query) = []
            def lookup_code(_system, _code) = nil
            def validate_code(_system, _code, valueset_id:) = false
          end

          AdapterFactory.register("IRIS") { iris_sentinel.new }

          assert_equal "IRIS-NORM", AdapterFactory.build("IRIS").expand_valueset("any").first[:code]

          ENV["TERMINOLOGY_BACKEND"] = "iris"
          assert_equal "IRIS-NORM", AdapterFactory.build.expand_valueset("any").first[:code]

          service = TerminologyService.new(backend: "IRIS")
          assert_equal :iris, service.backend
          assert_equal "IRIS-NORM", service.expand_valueset("any").first[:code]

          local = AdapterFactory.build(" local ")
          assert_kind_of LocalAdapter, local
          assert_equal :local, local.backend
        end

        test "build rejects non-string backend names with ArgumentError not NoMethodError" do
          assert_raises(ArgumentError) { AdapterFactory.build(false) }
          assert_raises(ArgumentError) { AdapterFactory.build(1) }
        end
      end
    end
  end
end
