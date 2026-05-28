# frozen_string_literal: true

begin
  require "rpms_rpc/api/notifications"
rescue LoadError
  # rpms-rpc gem does not yet expose RpmsRpc::Notifications.
end

module Lakeraven
  module EHR
    # Clinician alert inbox — fires at login and on patient open.
    # Wraps RpmsRpc::Notifications (lakeraven/rpms-rpc#74).
    class NotificationsGateway
      MARK_READ_FAILURE = { success: false, raw: nil }.freeze

      def self.inbox(user_duz, unread: nil, via: default_provider)
        return [] if via.nil?

        via.inbox(user_duz.to_s, unread: unread)
      end

      def self.mark_read(notification_ien, user_duz, via: default_provider)
        return MARK_READ_FAILURE if via.nil?

        via.mark_read(notification_ien.to_s, user_duz.to_s)
      end

      def self.default_provider
        return nil unless defined?(::RpmsRpc::Notifications) &&
                          ::RpmsRpc::Notifications.respond_to?(:inbox)
        ::RpmsRpc::Notifications
      end
    end
  end
end
