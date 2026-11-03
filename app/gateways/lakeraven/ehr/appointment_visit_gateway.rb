# frozen_string_literal: true

require "rpms_rpc/api/scheduling"

module Lakeraven
  module EHR
    # The patient's day at the clinic after check-in: check-out (rpms-ux
    # S-SCH-07), undoing a check-in (S-SCH-03.9) or a check-out (S-SCH-07.6),
    # and a no-show (S-SCH-08), each through the BSDX RPC the Windows
    # scheduling client sends:
    #
    #   check_out     BSDX CHECKOUT APPOINTMENT   (CHECKOUT^BSDX25)
    #   undo_checkin  BSDX CHECKIN APPOINTMENT "@" (CANCHKIN^BSDX25)
    #   undo_checkout BSDX CANCEL CHECKOUT APPT   (CANCKOUT^BSDX25)
    #   no_show       BSDX NOSHOW 1 / 0           (NOSHOW^BSDX31)
    #
    # Only BSDX CHECKOUT and CANCEL CHECKOUT refuse an appointment in the wrong
    # state. Undoing a check-in that is not there, and marking a no-show twice,
    # or on a checked-in appointment, all answer success on a built image; so
    # the caller checks the state first.
    #
    # When RPMS gives no answer, or the routine errors after part of the write
    # (BSDX25 files BSDX APPOINTMENT before #44, with no rollback, as #727 found
    # for check-in), the appointment is read again: if it now shows the change,
    # the change is reported as done.
    class AppointmentVisitGateway
      Result = Data.define(:status, :message) do
        def done? = status == :done
      end

      # How each change shows on the appointment as BSDX CREATE APPT SCHEDULE
      # lists it once it is filed.
      FILED = {
        check_out: ->(a) { a[:checkout_time].present? },
        undo_checkin: ->(a) { a[:checkin_time].blank? },
        undo_checkout: ->(a) { a[:checkout_time].blank? },
        no_show: ->(a) { a[:no_show] },
        undo_no_show: ->(a) { !a[:no_show] }
      }.freeze

      # appointment: the row from AppointmentBookingGateway.appointment.
      # reread: returns the appointment as RPMS now has it.
      def self.check_out(appointment, at:, reread:, via: ::RpmsRpc::Scheduling)
        change(:check_out, reread) do
          via.checkout_appointment(appointment[:id], patient_dfn: appointment[:patient_dfn],
                                                     appointment_time: appointment[:start_time], checkout_time: at)
        end
      end

      def self.undo_checkin(appointment, reread:, via: ::RpmsRpc::Scheduling)
        change(:undo_checkin, reread) { via.cancel_checkin(appointment[:id]) }
      end

      def self.undo_checkout(appointment, reread:, via: ::RpmsRpc::Scheduling)
        change(:undo_checkout, reread) { via.cancel_checkout(appointment[:id]) }
      end

      def self.no_show(appointment, reread:, via: ::RpmsRpc::Scheduling)
        change(:no_show, reread) { via.mark_no_show(appointment[:id], no_show: true) }
      end

      def self.undo_no_show(appointment, reread:, via: ::RpmsRpc::Scheduling)
        change(:undo_no_show, reread) { via.mark_no_show(appointment[:id], no_show: false) }
      end

      def self.change(kind, reread)
        reply = begin
          yield
        rescue ::RpmsRpc::Error, IOError, SystemCallError => e
          Rails.logger.error("[scheduling] #{kind} raised #{e.class}; the outcome is unknown")
          nil
        end
        return Result.new(status: :done, message: nil) if reply&.dig(:success)
        return Result.new(status: :done, message: reply&.dig(:error).presence) if filed?(kind, reread)
        return Result.new(status: :unknown, message: nil) if reply.nil?

        Result.new(status: :refused, message: reply[:error].to_s)
      end
      private_class_method :change

      def self.filed?(kind, reread)
        appointment = reread.call
        appointment.present? && FILED.fetch(kind).call(appointment)
      rescue ::RpmsRpc::Error, IOError, SystemCallError
        false
      end
      private_class_method :filed?
    end
  end
end
