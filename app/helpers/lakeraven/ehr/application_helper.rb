# frozen_string_literal: true

module Lakeraven
  module EHR
    module ApplicationHelper
      # The front desk's shared view pieces (docs/DESIGN-SYSTEM.md).
      include ComponentsHelper

      def feature_available?(capability)
        BackendRegistry.current.provides?(capability)
      end

      # Whether the patient bar offers its search (rpms-ux S-CHT-01): the
      # controller decides; one that does not say offers none.
      def patient_search_allowed?
        controller.respond_to?(:patient_search_allowed?) && controller.patient_search_allowed?
      end

      # An appointment's state in words, the clinic day's and the week's:
      # [key, label], the key for data-status and styling, the label for people.
      def appointment_status(appointment)
        if appointment[:cancelled] then [ "cancelled", "Cancelled" ]
        elsif appointment[:no_show] then [ "no-show", "No-show" ]
        elsif appointment[:checkin_time] then [ "checked", "Checked in #{appointment[:checkin_time].strftime('%H:%M')}" ]
        else [ "booked", "Booked" ]
        end
      end

      # Why a clinic day takes no booking (ClinicDay.closed_on), in words.
      CLOSED_REASONS = { holiday: "Holiday", beyond_booking: "Past the booking limit", inactive: "Clinic inactive" }.freeze

      def closed_reason(reason) = CLOSED_REASONS.fetch(reason, reason.to_s.humanize)
    end
  end
end
