# frozen_string_literal: true

require "rpms_rpc/api/notifications"
require "rpms_rpc/api/user_management"

module Lakeraven
  module EHR
    # The signed-in user's notifications (alerts), read and acted on in RPMS
    # as that user, through the RPCs VueCentric's Notifications tab sends
    # (RpmsRpc::Notifications):
    #
    #   inbox    BEHOXQ ALRLIST  the list (rpms-ux S-SGN-02.1)
    #   remove   BEHOXQ ALRPP    remove one RPMS lists CAN DELETE (S-SGN-02.2, 02.3)
    #   forward  BEHOXQ FORWARD  forward one to colleagues, with a comment (S-SGN-02.4)
    #   text     BEHOXQ ALRMSG   a forwarded one's comment, or an alert's long text
    #
    # RPMS answers for the session's own user, so no user is passed.
    class NotificationsGateway
      # What a write came to. :done when RPMS did it; :refused when RPMS (or
      # the gem, on RPMS's own rules) would not; :unknown
      # when the call failed part way, so it may or may not have happened.
      Result = Data.define(:status) do
        def done? = status == :done
        def refused? = status == :refused
      end

      class << self
        # The user's notifications, newest first. A failed read raises the
        # gem's error, so a caller never mistakes it for "none".
        def inbox
          ::RpmsRpc::Notifications.inbox.sort_by { |n| n[:delivered_at] || Time.at(0) }.reverse
        end

        # One of the user's notifications, by its alert ID, or nil when RPMS
        # does not list it for them.
        def find(alert_id)
          id = alert_id.to_s
          inbox.find { |n| n[:alert_id] == id }
        end

        # The lines BEHOXQ ALRMSG answers for the user's copy: on a forwarded
        # notification, the forwarding comment; on another, the alert's long
        # text, when it has one. [] when there is neither.
        def text(alert_id)
          ::RpmsRpc::Notifications.message(alert_id)
        end

        # Remove the notification from the user's list. The gem sends it only
        # when RPMS lists it CAN DELETE and confirms it is gone by reading the
        # list again.
        def remove(alert_id)
          write { ::RpmsRpc::Notifications.remove(alert_id) }
        end

        # Forward the notification to one user, by DUZ, with an optional
        # comment. The user keeps their own copy.
        def forward(alert_id, to:, comment:)
          write { ::RpmsRpc::Notifications.forward(alert_id, to: [ to ], comment: comment.presence) }
        end

        # The users whose names start with +text+, for choosing whom to forward
        # to: ORWU NEWPERS (RpmsRpc::UserManagement.search), the active users
        # of NEW PERSON. It answers a page of the name index starting AT the
        # text, so only names that begin with it are kept, as
        # PractitionerGateway.search does. Kernel's system entries (.5
        # POSTMASTER, .6 SHARED,MAIL) are not people and are left out, as is
        # +except+ (the user themself).
        def recipients(text, except: nil)
          prefix = text.to_s.strip.upcase
          return [] if prefix.empty?

          ::RpmsRpc::UserManagement.search(prefix).filter_map do |row|
            duz = row[:duz].to_s
            name = row[:name].to_s
            next unless duz.match?(/\A[1-9]\d*\z/) && name.upcase.start_with?(prefix)
            next if duz == except.to_s

            { duz: duz, name: name }
          end
        end

        private

        def write
          yield
          Result.new(status: :done)
        rescue ::RpmsRpc::Notifications::RefusedError, ArgumentError
          Result.new(status: :refused)
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          Rails.logger.error("[notifications] write raised #{e.class}; the outcome is unknown")
          Result.new(status: :unknown)
        end
      end
    end
  end
end
