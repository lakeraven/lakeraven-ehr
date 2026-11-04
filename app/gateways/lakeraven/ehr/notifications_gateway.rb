# frozen_string_literal: true

require "rpms_rpc/api/notifications"

module Lakeraven
  module EHR
    # The signed-in user's notifications (alerts), read from RPMS as that
    # user (rpms-ux S-SGN-02.1). Wraps RpmsRpc::Notifications.inbox, which
    # sends BEHOXQ ALRLIST, the read behind VueCentric's Notifications tab:
    # RPMS answers for the session's own user, so no user is passed.
    #
    # Read only. Removing or forwarding a notification needs a write the gem
    # does not send yet (lakeraven/rpms-rpc#595).
    class NotificationsGateway
      # The user's notifications, newest first. A failed read raises the
      # gem's error, so a caller never mistakes it for "none".
      def self.inbox
        ::RpmsRpc::Notifications.inbox.sort_by { |n| n[:delivered_at] || Time.at(0) }.reverse
      end
    end
  end
end
