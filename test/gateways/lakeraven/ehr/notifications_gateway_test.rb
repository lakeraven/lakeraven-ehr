# frozen_string_literal: true

require "test_helper"

# Tests for NotificationsGateway — clinician alert inbox.
# Wraps RpmsRpc::Notifications (lakeraven/rpms-rpc#74).
module Lakeraven
  module EHR
    class NotificationsGatewayTest < ActiveSupport::TestCase
      class FakeNotificationsAPI
        attr_reader :calls

        def initialize(returns: {})
          @returns = returns
          @calls = []
        end

        def inbox(user_duz, unread: nil)
          @calls << { method: :inbox, args: [ user_duz ], unread: unread }
          @returns[:inbox] || []
        end

        def mark_read(notification_ien, user_duz)
          @calls << { method: :mark_read, args: [ notification_ien, user_duz ] }
          @returns[:mark_read] || { success: true, raw: "0" }
        end
      end

      # --- via: nil ---

      test "inbox returns empty when no provider is available" do
        assert_equal [], NotificationsGateway.inbox("301", via: nil)
      end

      test "mark_read returns failure shape when no provider is available" do
        assert_equal({ success: false, raw: nil },
          NotificationsGateway.mark_read(1001, "301", via: nil))
      end

      # --- delegation ---

      test "inbox delegates with duz coerced and unread filter passed through" do
        items = [ { ien: 1, message: "Lab result ready" } ]
        fake = FakeNotificationsAPI.new(returns: { inbox: items })

        result = NotificationsGateway.inbox(301, unread: true, via: fake)

        assert_equal items, result
        assert_equal [ "301" ], fake.calls.first[:args]
        assert_equal true, fake.calls.first[:unread]
      end

      test "inbox defaults unread to nil when omitted" do
        fake = FakeNotificationsAPI.new(returns: { inbox: [] })

        NotificationsGateway.inbox("301", via: fake)

        assert_nil fake.calls.first[:unread]
      end

      test "mark_read delegates with identifiers coerced to strings" do
        fake = FakeNotificationsAPI.new(returns: { mark_read: { success: true, raw: "0" } })

        result = NotificationsGateway.mark_read(1001, 301, via: fake)

        assert_equal({ success: true, raw: "0" }, result)
        assert_equal [ "1001", "301" ], fake.calls.first[:args]
      end

      # --- default_provider ---

      test "default_provider resolves to RpmsRpc::Notifications when the gem ships it" do
        provider = NotificationsGateway.default_provider
        refute_nil provider, "expected RpmsRpc::Notifications to be loaded via the gateway's guarded require"
        assert_equal "RpmsRpc::Notifications", provider.name
      end
    end
  end
end
