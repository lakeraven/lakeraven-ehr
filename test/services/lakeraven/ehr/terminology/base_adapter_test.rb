# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module Terminology
      class BaseAdapterTest < ActiveSupport::TestCase
        setup do
          @adapter = BaseAdapter.new
        end

        test "expand_valueset raises NotImplementedError" do
          assert_raises(NotImplementedError) { @adapter.expand_valueset("any-id") }
        end

        test "get_valueset raises NotImplementedError" do
          assert_raises(NotImplementedError) { @adapter.get_valueset("any-id") }
        end

        test "list_valuesets raises NotImplementedError" do
          assert_raises(NotImplementedError) { @adapter.list_valuesets }
        end

        test "search raises NotImplementedError" do
          assert_raises(NotImplementedError) { @adapter.search("query") }
        end

        test "lookup_code raises NotImplementedError" do
          assert_raises(NotImplementedError) { @adapter.lookup_code("http://example.com", "code") }
        end

        test "validate_code raises NotImplementedError" do
          assert_raises(NotImplementedError) do
            @adapter.validate_code("http://example.com", "code", valueset_id: "vs")
          end
        end

        test "backend raises NotImplementedError" do
          assert_raises(NotImplementedError) { @adapter.backend }
        end
      end
    end
  end
end
