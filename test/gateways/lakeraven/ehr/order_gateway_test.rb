# frozen_string_literal: true

require "test_helper"

# Tests for OrderGateway — clinical-order list APIs.
# Wraps RpmsRpc::Order (lakeraven/rpms-rpc#68).
module Lakeraven
  module EHR
    class OrderGatewayTest < ActiveSupport::TestCase
      # Replies as a fresh rpms-ydb e9b78c8 sent them for DFN 4 (DEMO,PATIENT
      # ONE, whose one order the rpms-ops demo seed files), replayed through the
      # real RpmsRpc::Order, so a change to the gem's signature fails here.
      AGET_DFN4 = [ "1^2^3261024.062548", "1;1^13^3261023.2048^^" ].freeze
      UNSIGN_DFN4 = [ "1;1^206^Nursing^0^0^0^0" ].freeze

      def seed_live_replies
        RpmsRpc.client.seed_raw_lines(:orders_list, "4", AGET_DFN4)
        RpmsRpc.client.seed_raw_lines(:orders_unsigned, "4", UNSIGN_DFN4)
      end

      # --- via: nil ---

      test "unsigned_for_patient returns empty when no provider is available" do
        assert_equal [], OrderGateway.unsigned_for_patient(4, via: nil)
      end

      test "list returns empty when no provider is available" do
        assert_equal [], OrderGateway.list(4, via: nil)
      end

      # --- through RpmsRpc::Order ---

      test "unsigned_for_patient sends the patient and reads the order actions" do
        seed_live_replies

        assert_equal [ { order_id: "1;1", ien: 1, action_ien: 1 } ], OrderGateway.unsigned_for_patient(4)
        assert_equal [ "4" ], RpmsRpc.client.received_calls.last[:params]
      end

      test "list sends the active view and the default display group, and reads the rows" do
        seed_live_replies

        rows = OrderGateway.list(4)

        assert_equal [ "1;1" ], rows.map { |r| r[:order_id] }
        assert_equal [ "4", "2", "1" ], RpmsRpc.client.received_calls.last[:params]
      end

      test "list passes a named view through to ORWORR AGET" do
        seed_live_replies

        OrderGateway.list(4, filter: :unsigned, display_group: 13)

        assert_equal [ "4", "11", "13" ], RpmsRpc.client.received_calls.last[:params]
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
