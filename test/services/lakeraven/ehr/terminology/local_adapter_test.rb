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

        test "invalid ValueSet ids are never read from disk" do
          leak_dir = Dir.mktmpdir("lakeraven-leak-valuesets")
          leak_json = File.join(leak_dir, "LEAKED.json")
          File.write(
            leak_json,
            {
              resourceType: "ValueSet",
              id: "LEAKED",
              title: "Leaked",
              status: "active",
              compose: {
                include: [
                  {
                    system: "http://example.com/leaked",
                    concept: [ { code: "LEAKED-CODE", display: "Leaked code" } ]
                  }
                ]
              }
            }.to_json
          )
          TerminologyService.additional_valueset_paths = [ TEST_VALUESETS ]
          adapter = LocalAdapter.new
          leak_id = leak_json.delete_suffix(".json")

          invalid_ids = [
            leak_id,
            "../../..",
            ".",
            "..",
            ".hidden-valueset",
            "nested/segment",
            "bad id",
            "foo\\bar"
          ]

          invalid_ids.each do |bad_id|
            assert_raises(TerminologyService::ValueSetNotFoundError) { adapter.expand_valueset(bad_id) }
            assert_raises(TerminologyService::ValueSetNotFoundError) { adapter.get_valueset(bad_id) }
            assert_raises(TerminologyService::ValueSetNotFoundError) do
              adapter.validate_code("http://example.com/leaked", "LEAKED-CODE", valueset_id: bad_id)
            end
          end

          assert_nil adapter.lookup_code("http://example.com/leaked", "LEAKED-CODE")

          assert adapter.list_valuesets.any?, "list_valuesets must remain usable"
          assert adapter.search("diabetes").any?, "search must remain usable"
        ensure
          FileUtils.remove_entry(leak_dir) if leak_dir
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
