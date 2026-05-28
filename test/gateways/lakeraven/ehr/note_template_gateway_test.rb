# frozen_string_literal: true

require "test_helper"

# Tests for NoteTemplateGateway — TIU note template tree, boilerplate text,
# and per-user access level. Wraps RpmsRpc::NoteTemplate (lakeraven/rpms-rpc#56).
module Lakeraven
  module EHR
    class NoteTemplateGatewayTest < ActiveSupport::TestCase
      class FakeNoteTemplateAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def roots(user_duz)
          @calls << { method: :roots, args: [ user_duz ] }
          @returns[:roots] || []
        end

        def items(template_ien)
          @calls << { method: :items, args: [ template_ien ] }
          @returns[:items] || []
        end

        def boilerplate(template_ien, dfn:, visit_ien:)
          @calls << { method: :boilerplate, args: [ template_ien, dfn, visit_ien ] }
          @returns[:boilerplate]
        end

        def text(template_ien)
          @calls << { method: :text, args: [ template_ien ] }
          @returns[:text]
        end

        def access_level(template_ien, user_duz)
          @calls << { method: :access_level, args: [ template_ien, user_duz ] }
          @returns[:access_level]
        end
      end

      # --- via: nil ---

      test "roots returns empty when no provider is available" do
        assert_equal [], NoteTemplateGateway.roots("301", via: nil)
      end

      test "items returns empty when no provider is available" do
        assert_equal [], NoteTemplateGateway.items(101, via: nil)
      end

      test "boilerplate returns nil when no provider is available" do
        assert_nil NoteTemplateGateway.boilerplate(101, dfn: 1, visit_ien: 2090061, via: nil)
      end

      test "text returns nil when no provider is available" do
        assert_nil NoteTemplateGateway.text(101, via: nil)
      end

      test "access_level returns nil when no provider is available" do
        assert_nil NoteTemplateGateway.access_level(101, "301", via: nil)
      end

      # --- delegation + coercion ---

      test "roots delegates with duz coerced to a string" do
        list = [ { ien: 7, name: "Primary Care" } ]
        fake = FakeNoteTemplateAPI.new(returns: { roots: list })

        assert_equal list, NoteTemplateGateway.roots(301, via: fake)
        assert_equal [ "301" ], fake.calls.first[:args]
      end

      test "items delegates with template_ien coerced to a string" do
        list = [ { ien: 12, title: "ROS" } ]
        fake = FakeNoteTemplateAPI.new(returns: { items: list })

        assert_equal list, NoteTemplateGateway.items(7, via: fake)
        assert_equal [ "7" ], fake.calls.first[:args]
      end

      test "boilerplate delegates with all identifiers coerced to strings" do
        fake = FakeNoteTemplateAPI.new(returns: { boilerplate: "S: Patient seen for..." })

        result = NoteTemplateGateway.boilerplate(7, dfn: 1, visit_ien: 2090061, via: fake)

        assert_equal "S: Patient seen for...", result
        assert_equal [ "7", "1", "2090061" ], fake.calls.first[:args]
      end

      test "text delegates" do
        fake = FakeNoteTemplateAPI.new(returns: { text: "S: {PATIENT NAME}" })
        assert_equal "S: {PATIENT NAME}", NoteTemplateGateway.text(7, via: fake)
      end

      test "access_level delegates" do
        fake = FakeNoteTemplateAPI.new(returns: { access_level: "READ" })
        assert_equal "READ", NoteTemplateGateway.access_level(7, "301", via: fake)
        assert_equal [ "7", "301" ], fake.calls.first[:args]
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::NoteTemplate when the gem ships it" do
        provider = NoteTemplateGateway.default_provider
        refute_nil provider, "expected RpmsRpc::NoteTemplate to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::NoteTemplate", provider.name
      end
    end
  end
end
