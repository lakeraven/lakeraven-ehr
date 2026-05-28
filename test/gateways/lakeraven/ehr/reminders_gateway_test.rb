# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class RemindersGatewayTest < ActiveSupport::TestCase
      # Test double for the eventual RpmsRpc::Reminders module — captures
      # calls so we can prove the gateway actually delegates.
      class FakeRemindersAPI
        attr_reader :calls

        def initialize(returns)
          @returns = returns
          @calls = []
        end

        def for_visit(dfn, visit_ien)
          @calls << { dfn: dfn, visit_ien: visit_ien }
          @returns
        end
      end

      test "for_visit returns empty array when no provider is available" do
        result = RemindersGateway.for_visit(8791, 2090061, via: nil)
        assert_equal [], result
      end

      test "for_visit delegates to the provider's for_visit with dfn and visit_ien" do
        reminders = [ { id: 1, name: "Annual physical due" } ]
        fake = FakeRemindersAPI.new(reminders)
        result = RemindersGateway.for_visit(8791, 2090061, via: fake)

        assert_equal reminders, result
        # Gateway normalizes identifiers to strings before delegating.
        assert_equal [ { dfn: "8791", visit_ien: "2090061" } ], fake.calls
      end

      test "default_provider resolves to RpmsRpc::Reminders now that the gem ships it" do
        provider = RemindersGateway.default_provider
        refute_nil provider, "expected RpmsRpc::Reminders to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::Reminders", provider.name
      end
    end
  end
end
