# frozen_string_literal: true

require "test_helper"
require_relative "support/adapter_contract"
require_relative "support/blank_input_adapter_examples"

module Lakeraven
  module EHR
    module Terminology
      class MockAdapterTest < ActiveSupport::TestCase
        include AdapterContract
        include BlankInputAdapterExamples

        def build_mock_adapter
          MockAdapter.new(valuesets: mock_valuesets_hash)
        end

        setup do
          @adapter = build_mock_adapter
        end

        test "backend is mock" do
          assert_equal :mock, @adapter.backend
        end

        test "satisfies shared adapter contract over in-memory valuesets hash" do
          assert_adapter_contract(@adapter)
        end

        test "lookup_code and validate_code refuse blank system or code" do
          assert_blank_inputs_never_verify(
            @adapter,
            valid_system: AdapterContract::ICD9_SYSTEM,
            valid_code: AdapterContract::SAMPLE_CODE,
            valueset_id: AdapterContract::VALUESET_ID
          )
        end

        test "skips codes without system or with blank code fields" do
          adapter = MockAdapter.new(
            valuesets: {
              "spec-mock-blank-codes" => {
                "title" => "Mock blank code fixture",
                "codes" => [
                  { system: nil, code: "ORPHAN", display: "Missing system" },
                  { system: "http://example.com/mock-blank", code: "", display: "Blank code" },
                  { system: "http://example.com/mock-blank", code: "GOOD", display: "Good code" }
                ]
              }
            }
          )

          assert_nil adapter.lookup_code("http://example.com/mock-blank", "ORPHAN")
          refute adapter.validate_code("http://example.com/mock-blank", "ORPHAN", valueset_id: "spec-mock-blank-codes")
          refute adapter.validate_code("http://example.com/mock-blank", "", valueset_id: "spec-mock-blank-codes")
          assert_nil adapter.lookup_code("http://example.com/mock-blank", nil)
          refute adapter.validate_code("http://example.com/mock-blank", nil, valueset_id: "spec-mock-blank-codes")
          assert adapter.validate_code("http://example.com/mock-blank", "GOOD", valueset_id: "spec-mock-blank-codes")
        end

        private

        def mock_valuesets_hash
          {
            AdapterContract::VALUESET_ID => {
              "title" => "Diabetes Diagnosis Codes",
              "codes" => [
                {
                  system: AdapterContract::ICD10_SYSTEM,
                  code: "E11.9",
                  display: "Type 2 diabetes mellitus without complications"
                },
                {
                  system: AdapterContract::ICD9_SYSTEM,
                  code: AdapterContract::SAMPLE_CODE,
                  display: "Diabetes mellitus without complication"
                }
              ]
            }
          }
        end
      end
    end
  end
end
