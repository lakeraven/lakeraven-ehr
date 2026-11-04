# frozen_string_literal: true

require "test_helper"
require_relative "support/adapter_contract"
require_relative "support/blank_input_adapter_examples"

module Lakeraven
  module EHR
    module Terminology
      class LocalAdapterTest < ActiveSupport::TestCase
        include AdapterContract
        include BlankInputAdapterExamples

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

        test "get_valueset returns nil without reading disk for nil malformed and hidden ids" do
          leak_dir = Dir.mktmpdir("lakeraven-leak-valuesets")
          write_leak_valueset(leak_dir)
          TerminologyService.additional_valueset_paths = [ leak_dir, TEST_VALUESETS ]
          adapter = LocalAdapter.new

          [ nil, "bad id", ".hidden" ].each do |bad_id|
            assert_nil adapter.get_valueset(bad_id),
                       "get_valueset(#{bad_id.inspect}) must return nil, not raise"
          end
        ensure
          FileUtils.remove_entry(leak_dir) if leak_dir
        end

        test "expand and validate raise ValueSetNotFoundError for nil malformed and hidden ids without disk read" do
          leak_dir = Dir.mktmpdir("lakeraven-leak-valuesets")
          write_leak_valueset(leak_dir)
          TerminologyService.additional_valueset_paths = [ leak_dir, TEST_VALUESETS ]
          adapter = LocalAdapter.new

          [ nil, "bad id", ".hidden" ].each do |bad_id|
            assert_raises(TerminologyService::ValueSetNotFoundError) { adapter.expand_valueset(bad_id) }
            assert_raises(TerminologyService::ValueSetNotFoundError) do
              adapter.validate_code("http://example.com/leaked", "LEAKED-CODE", valueset_id: bad_id)
            end
          end
        ensure
          FileUtils.remove_entry(leak_dir) if leak_dir
        end

        test "invalid ValueSet ids are never read from disk" do
          leak_dir = Dir.mktmpdir("lakeraven-leak-valuesets")
          leak_json = File.join(leak_dir, "LEAKED.json")
          write_leak_valueset(leak_dir)
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

        test "lookup_code and validate_code refuse blank system or code" do
          assert_blank_inputs_never_verify(
            @adapter,
            valid_system: AdapterContract::ICD9_SYSTEM,
            valid_code: AdapterContract::SAMPLE_CODE,
            valueset_id: AdapterContract::VALUESET_ID
          )
        end

        test "skips concepts without code and includes without system" do
          extra_dir = Dir.mktmpdir("lakeraven-blank-concept-valuesets")
          File.write(
            File.join(extra_dir, "spec-blank-concepts-valueset.json"),
            {
              resourceType: "ValueSet",
              id: "spec-blank-concepts-valueset",
              title: "Blank concept fixture",
              status: "active",
              compose: {
                include: [
                  {
                    concept: [ { code: "ORPHAN", display: "No system on include" } ]
                  },
                  {
                    system: "http://example.com/synthetic-blank",
                    concept: [
                      { display: "Missing code" },
                      { code: "VALID-1", display: "Valid code" },
                      { code: "", display: "Blank code string" }
                    ]
                  }
                ]
              }
            }.to_json
          )
          TerminologyService.additional_valueset_paths = [ TEST_VALUESETS, extra_dir ]
          adapter = LocalAdapter.new

          assert_nil adapter.lookup_code("http://example.com/synthetic-blank", "ORPHAN")
          refute adapter.validate_code("http://example.com/synthetic-blank", "ORPHAN",
                                       valueset_id: "spec-blank-concepts-valueset")

          lookup = adapter.lookup_code("http://example.com/synthetic-blank", "VALID-1")
          assert_equal "VALID-1", lookup[:code]
          assert adapter.validate_code("http://example.com/synthetic-blank", "VALID-1",
                                       valueset_id: "spec-blank-concepts-valueset")
          refute adapter.validate_code("", "VALID-1", valueset_id: "spec-blank-concepts-valueset")
          assert_nil adapter.lookup_code("http://example.com/synthetic-blank", nil)
          refute adapter.validate_code("http://example.com/synthetic-blank", nil,
                                       valueset_id: "spec-blank-concepts-valueset")
        ensure
          FileUtils.remove_entry(extra_dir) if extra_dir
        end

        def write_leak_valueset(leak_dir)
          File.write(
            File.join(leak_dir, "LEAKED.json"),
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
