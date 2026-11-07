# frozen_string_literal: true

module Lakeraven
  module EHR
    # The signed-in user's landing page. Every count on it is read from RPMS
    # as this user and links to the page where that work is done (#812); a
    # count with no such page is not shown.
    class DashboardsController < WebController
      rate_limit only: :show

      before_action :require_authentication

      # Today's appointments in each clinic the user schedules for (rpms-ux
      # S-SCH-05.1, S-SCH-05.3), linking to that clinic's day. Shown to a user
      # who may open scheduling, on a backend that serves it (#647).
      #
      # The appointments needing action today in those clinics (rpms-ux
      # S-SCH-13.5, #875), linking to their list.
      #
      # The user's notifications (rpms-ux S-SGN-02.1), linking to their list.
      # Shown to a user who may read the chart, as the list is (#874).
      def show
        @today = Date.today
        @clinic_counts = todays_clinic_counts if schedules?
        @needing_action = needing_action_count if schedules?
        @notification_count = notification_count if patient_search_allowed?
        @pending_referrals = pending_referral_count if works_referrals?
      end

      private

      # The referrals pending at the facility in the list's default window
      # (#873), for a user who works referrals, on a backend that serves RCIS.
      def works_referrals?
        BackendRegistry.current.provides?(:prc_referrals) && capability?("referrals.work")
      end

      # { window:, count: } for PendingReferralsController's default window,
      # or :unread when RPMS does not answer: a failed read is never zero.
      def pending_referral_count
        window = PendingReferralWindow.default(@today)
        { window: window, count: ServiceRequestGateway.pending(window).size }
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[dashboard] pending referrals raised #{e.class}")
        :unread
      end

      def schedules?
        BackendRegistry.current.provides?(:bprm_scheduling) && capability?("scheduling.open")
      end

      # [{ resource:, count: }] for the clinics scheduling offers this user
      # (Scheduling::BaseController#visible?: their BSDX rights name them, or
      # every one for a supervisor), or :unread when RPMS does not answer: a
      # failed read is said so, never shown as zero.
      def todays_clinic_counts
        counts = AppointmentBookingGateway.booked_counts(@today)
        my_clinics.map do |resource|
          { resource: resource, count: counts.fetch(resource[:name], 0) }
        end
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[dashboard] today's appointments raised #{e.class}")
        :unread
      end

      # { window:, count: } for the needing-action list's default window, today,
      # or :unread when RPMS does not answer: a failed read is never zero.
      def needing_action_count
        window = NeedingActionWindow.default(@today)
        { window: window, count: AppointmentBookingGateway.needing_action(my_clinics, window).size }
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[dashboard] appointments needing action raised #{e.class}")
        :unread
      end

      # The clinics scheduling offers this user, read once per request.
      def my_clinics
        @my_clinics ||= begin
          supervisor = capability?("scheduling.supervise")
          AppointmentBookingGateway.resources.select { |r| r[:view] || supervisor }
        end
      end

      # How many notifications RPMS holds for the user: the rows of the list
      # the count links to. :unread when RPMS does not answer.
      def notification_count
        NotificationsGateway.inbox.size
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[dashboard] notifications raised #{e.class}")
        :unread
      end
    end
  end
end
