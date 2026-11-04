# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TerminologyServiceAdapterTest < ActiveSupport::TestCase
      setup do
        @original_terminology_backend = ENV["TERMINOLOGY_BACKEND"]
        @original_umls = ENV["UMLS_API_KEY"]
        @original_iris = ENV["IRIS_TERMINOLOGY_URL"]
        ENV["TERMINOLOGY_BACKEND"] = nil
        ENV["UMLS_API_KEY"] = nil
        ENV["IRIS_TERMINOLOGY_URL"] = nil
        Terminology::AdapterFactory.reset_registrations!
      end

      teardown do
        ENV["TERMINOLOGY_BACKEND"] = @original_terminology_backend
        ENV["UMLS_API_KEY"] = @original_umls
        ENV["IRIS_TERMINOLOGY_URL"] = @original_iris
        Terminology::AdapterFactory.reset_registrations!
      end

      test "adapter injection delegates expand_valueset to the injected adapter" do
        adapter = Terminology::MockAdapter.new(valuesets: {
          "demo-vs" => {
            "title" => "Demo",
            "codes" => [
              { system: "http://example.com/demo", code: "D1", display: "Demo code" }
            ]
          }
        })
        service = TerminologyService.new(adapter: adapter, use_distributed_cache: false)
        codes = service.expand_valueset("demo-vs")
        assert_equal "D1", codes.first[:code]
        assert_equal :mock, service.backend
      end

      test "adapter injection delegates code_in_valueset to the injected adapter" do
        adapter = Terminology::MockAdapter.new(valuesets: {
          "demo-vs" => {
            "title" => "Demo",
            "codes" => [
              { system: "http://example.com/demo", code: "D1", display: "Demo code" }
            ]
          }
        })
        service = TerminologyService.new(adapter: adapter, use_distributed_cache: false)
        assert service.code_in_valueset?("D1", "demo-vs", system: "http://example.com/demo")
        refute service.code_in_valueset?("MISSING", "demo-vs")
      end

      test "adapter injection delegates get_valueset list_valuesets and search" do
        adapter = Terminology::MockAdapter.new(valuesets: {
          "demo-vs" => {
            "title" => "Unique Mock Title",
            "codes" => [ { system: "http://example.com/demo", code: "D1", display: "Demo code" } ]
          }
        })
        service = TerminologyService.new(adapter: adapter, use_distributed_cache: false)

        valueset = service.get_valueset("demo-vs")
        assert_equal "ValueSet", valueset["resourceType"]

        assert service.list_valuesets.any? { |vs| vs["title"] == "Unique Mock Title" }
        assert service.search("Unique Mock").any?
      end

      test "unregistered iris backend raises AdapterNotAvailable on expand and does not use local JSON" do
        service = TerminologyService.new(backend: :iris, use_distributed_cache: false)
        assert_equal :iris, service.backend
        assert_raises(Terminology::AdapterNotAvailable) do
          service.expand_valueset("gpra-bgpmu-diabetes-dx")
        end
      end
    end
  end
end
