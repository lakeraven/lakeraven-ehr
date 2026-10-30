# frozen_string_literal: true

require "test_helper"
require_relative "support/adapter_contract"

module Lakeraven
  module EHR
    module Terminology
      # Runs the same contract assertions against both built-in data backends.
      class AdapterContractTest < ActiveSupport::TestCase
        include AdapterContract

        TEST_VALUESETS = File.expand_path("../../../../fixtures/files/valuesets", __dir__)

        setup do
          @original_paths = TerminologyService.additional_valueset_paths
          TerminologyService.additional_valueset_paths = [ TEST_VALUESETS ]
        end

        teardown do
          TerminologyService.additional_valueset_paths = @original_paths
        end

        test "LocalAdapter and MockAdapter both satisfy the shared contract" do
          local = LocalAdapter.new
          mock = MockAdapter.new(valuesets: {
            VALUESET_ID => {
              "title" => "Diabetes Diagnosis Codes",
              "codes" => [
                { system: ICD10_SYSTEM, code: "E11.9", display: "Type 2 diabetes mellitus without complications" },
                { system: ICD9_SYSTEM, code: SAMPLE_CODE, display: "Diabetes mellitus without complication" }
              ]
            }
          })

          assert_adapter_contract(local)
          assert_adapter_contract(mock)
        end
      end
    end
  end
end
