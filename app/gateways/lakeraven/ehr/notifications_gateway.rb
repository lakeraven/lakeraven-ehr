# frozen_string_literal: true

require "rpms_rpc/api/notifications"

module Lakeraven
  module EHR
    # Clinician alert inbox — fires at login and on patient open.
    # Wraps RpmsRpc::Notifications. There is no mark-read: rpms-rpc #311
    # removed it with BQI MARK ALERT READ, and these alerts carry no per-user
    # read state to set.
    class NotificationsGateway
      def self.inbox(user_duz, unread: nil, via: default_provider)
        return [] if via.nil?

        via.inbox(user_duz.to_s, unread: unread)
      end

      def self.default_provider
        ::RpmsRpc::Notifications
      end
    end
  end
end
