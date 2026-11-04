# frozen_string_literal: true

module Lakeraven
  module EHR
    # The signed-in user's landing page. Every count on it is read from RPMS
    # as this user and links to the page where that work is done (#812); a
    # count with no such page is not shown.
    class DashboardsController < WebController
      before_action :require_authentication

      # Today's appointments in each clinic the user schedules for (rpms-ux
      # S-SCH-05.1, S-SCH-05.3), linking to that clinic's day. Shown to a user
      # who may open scheduling, on a backend that serves it (#647).
      def show
        @today = Date.today
        @clinic_counts = todays_clinic_counts if schedules?
      end

      private

      def schedules?
        BackendRegistry.current.provides?(:bprm_scheduling) && capability?("scheduling.open")
      end

      # [{ resource:, count: }] for the clinics scheduling offers this user
      # (Scheduling::BaseController#visible?: their BSDX rights name them, or
      # every one for a supervisor), or :unread when RPMS does not answer: a
      # failed read is said so, never shown as zero.
      def todays_clinic_counts
        supervisor = capability?("scheduling.supervise")
        counts = AppointmentBookingGateway.booked_counts(@today)
        AppointmentBookingGateway.resources.select { |r| r[:view] || supervisor }.map do |resource|
          { resource: resource, count: counts.fetch(resource[:name], 0) }
        end
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[dashboard] today's appointments raised #{e.class}")
        :unread
      end
    end
  end
end
