# frozen_string_literal: true

require "test_helper"
require_relative "support/adapter_contract"

module Lakeraven
  module EHR
    module Terminology
      class MockAdapterTest < ActiveSupport::TestCase
        include AdapterContract

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
