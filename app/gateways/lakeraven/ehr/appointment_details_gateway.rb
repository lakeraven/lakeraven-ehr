# frozen_string_literal: true

require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"

module Lakeraven
  module EHR
    # Keeping an appointment's details current (rpms-ux S-SCH-09).
    #
    # A booked appointment's note and length go through BSDX EDIT APPOINTMENT,
    # as the Windows scheduler sends them: it replaces the BSDX note and files
    # the new length on the clinic (#44.003 field 1), keeping the start. It
    # does not touch the clinic's own copy of the note (OTHER, #44.003 field 3),
    # so a changed note is filed there too (SchedulingSetup.set_clinic_note).
    #
    # A cancelled or no-show appointment's remarks are CANCELLATION REMARKS on
    # the patient (#2.98 field 17), which no BSDX RPC edits
    # (SchedulingSetup.set_cancellation_remarks).
    class AppointmentDetailsGateway
      Result = Data.define(:status, :message) do
        def saved? = status == :saved
      end

      # Whether the clinic lets an appointment's length change (S-SCH-09.4):
      # VARIABLE APPOINTMENT LENGTH (#44 field 1913), by BSDX CLINIC VAR APPT.
      # A failed read counts as no, so the length is never offered by default.
      def self.variable_length?(resource, via: ::RpmsRpc::Scheduling)
        via.variable_length?(resource[:hospital_location_id])
      rescue ::RpmsRpc::Error, IOError, SystemCallError
        false
      end

      # appointment: as BSDX CREATE APPT SCHEDULE lists it. length: the new
      # length, or nil to keep it.
      def self.update_booked(appointment, resource, note:, length:, via: ::RpmsRpc::Scheduling, setup: ::RpmsRpc::SchedulingSetup)
        reply = via.edit_appointment(appointment[:id], note: note, length_minutes: length)
        return failed(reply) unless reply&.dig(:success)
        return Result.new(status: :saved, message: nil) if note == appointment[:note].to_s.strip

        on_clinic = setup.set_clinic_note(hospital_location_id: resource[:hospital_location_id], start_time: appointment[:start_time],
                                          patient_dfn: appointment[:patient_dfn], note: note)
        return Result.new(status: :saved, message: nil) if on_clinic&.dig(:success)

        Result.new(status: :partial, message: "The note was saved on the appointment, but RPMS did not file it on the clinic (#{on_clinic&.dig(:error).presence || 'no reply'}). Save it again.")
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] appointment edit raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, message: nil)
      end

      def self.update_remarks(appointment, remarks:, setup: ::RpmsRpc::SchedulingSetup)
        failed(setup.set_cancellation_remarks(patient_dfn: appointment[:patient_dfn], start_time: appointment[:start_time], remarks: remarks), ok: true)
      rescue ::RpmsRpc::Error, IOError, SystemCallError => e
        Rails.logger.error("[scheduling] remarks edit raised #{e.class}; the outcome is unknown")
        Result.new(status: :unknown, message: nil)
      end

      def self.failed(reply, ok: false)
        return Result.new(status: :unknown, message: nil) if reply.nil?
        return Result.new(status: :saved, message: nil) if ok && reply[:success]

        Result.new(status: :refused, message: reply[:error].to_s)
      end
      private_class_method :failed
    end
  end
end
