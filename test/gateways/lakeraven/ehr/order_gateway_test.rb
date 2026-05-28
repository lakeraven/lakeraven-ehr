# frozen_string_literal: true

require "test_helper"

# Tests for OrderGateway — clinical-order list APIs.
# Wraps RpmsRpc::Order (lakeraven/rpms-rpc#68).
module Lakeraven
  module EHR
    class OrderGatewayTest < ActiveSupport::TestCase
      class FakeOrderAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def unsigned_for_user(user_duz)
          @calls << { method: :unsigned_for_user, args: [ user_duz ] }
          @returns[:unsigned_for_user] || []
        end

        def list(dfn, status: :all, view: :default)
          @calls << { method: :list, args: [ dfn ], status: status, view: view }
          @returns[:list] || []
        end
      end

      # --- via: nil ---

      test "unsigned_for_user returns empty when no provider is available" do
        assert_equal [], OrderGateway.unsigned_for_user("301", via: nil)
      end

      test "list returns empty when no provider is available" do
        assert_equal [], OrderGateway.list(1, via: nil)
      end

      # --- delegation + coercion ---

      test "unsigned_for_user delegates with duz coerced to a string" do
        orders = [ { ien: 1, type: "LAB" } ]
        fake = FakeOrderAPI.new(returns: { unsigned_for_user: orders })

        assert_equal orders, OrderGateway.unsigned_for_user(301, via: fake)
        assert_equal [ "301" ], fake.calls.first[:args]
      end

      test "list delegates with dfn coerced and symbolic taxonomies passed through" do
        orders = [ { ien: 1, status: "A" } ]
        fake = FakeOrderAPI.new(returns: { list: orders })

        result = OrderGateway.list(1, status: :pending, view: :active, via: fake)

        assert_equal orders, result
        assert_equal [ "1" ], fake.calls.first[:args]
        assert_equal :pending, fake.calls.first[:status]
        assert_equal :active, fake.calls.first[:view]
      end

      test "list defaults to status: :all and view: :default when omitted" do
        fake = FakeOrderAPI.new(returns: { list: [] })

        OrderGateway.list(1, via: fake)

        assert_equal :all, fake.calls.first[:status]
        assert_equal :default, fake.calls.first[:view]
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::Order when the gem ships it" do
        provider = OrderGateway.default_provider
        refute_nil provider, "expected RpmsRpc::Order to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::Order", provider.name
      end
    end
  end
end
