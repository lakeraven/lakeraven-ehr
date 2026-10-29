# frozen_string_literal: true

require "test_helper"
require_relative "support/adapter_contract"

module Lakeraven
  module EHR
    module Terminology
      class LocalAdapterTest < ActiveSupport::TestCase
        include AdapterContract

        TEST_VALUESETS = File.expand_path("../../../../fixtures/files/valuesets", __dir__)

        setup do
          @original_paths = TerminologyService.additional_valueset_paths
          TerminologyService.additional_valueset_paths = [ TEST_VALUESETS ]
          @adapter = LocalAdapter.new
        end

        teardown do
          TerminologyService.additional_valueset_paths = @original_paths
        end

        test "backend is local" do
          assert_equal :local, @adapter.backend
        end

        test "satisfies shared adapter contract against fixture valuesets" do
          assert_adapter_contract(@adapter)
        end

        test "honours TerminologyService.additional_valueset_paths" do
          extra_dir = Dir.mktmpdir("lakeraven-extra-valuesets")
          File.write(
            File.join(extra_dir, "extra-demo-valueset.json"),
            {
              resourceType: "ValueSet",
              id: "extra-demo-valueset",
              title: "Extra Demo",
              status: "active",
              compose: {
                include: [
                  {
                    system: "http://example.com/extra",
                    concept: [ { code: "X1", display: "Extra code" } ]
                  }
                ]
              }
            }.to_json
          )
          TerminologyService.additional_valueset_paths = [ extra_dir ]
          adapter = LocalAdapter.new
          codes = adapter.expand_valueset("extra-demo-valueset")
          assert_equal "X1", codes.first[:code]
        ensure
          FileUtils.remove_entry(extra_dir) if extra_dir
        end
      end
    end
  end
end
