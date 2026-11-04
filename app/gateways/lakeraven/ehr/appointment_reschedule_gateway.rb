# frozen_string_literal: true

require "rpms_rpc/api/scheduling"

module Lakeraven
  module EHR
    # Moving an appointment (rpms-ux S-SCH-02.8): in RPMS a reschedule is a new
    # booking plus the original cancelled with a reason, as BPRM's "Copy to
    # Reschedule" files it. BSDX has no RPC that does both, so they are done
    # here in the order that never loses the original:
    #
    # 1. the new time is booked (BSDX ADD NEW APPOINTMENT), under the same
    #    per-day lock and room check as any booking. If it is refused or full,
    #    nothing else is done and the original stays booked (S-SCH-02.10);
    # 2. then the original is cancelled (BSDX CANCEL APPOINTMENT). If that is
    #    refused, the new booking is cancelled again, so the patient keeps one
    #    appointment, the original.
    #
    # Only if that undo is refused too does the patient hold both; the result
    # says so, so the scheduler can cancel one by hand.
    #
    # A move to the same date and time at another clinic would be refused by
    # RPMS at step 1 (the patient already has an appointment then), so it is
    # refused here first; BPRM deletes the original for that case.
    class AppointmentRescheduleGateway
      Result = Data.define(:status, :appointment_id, :message) do
        def moved? = status == :moved
      end

      UNDO_REMARK = "Reschedule undone. The original appointment could not be cancelled"

      # original: the appointment as BSDX CREATE APPT SCHEDULE lists it.
      # overbook: as AppointmentBookingGateway.book_if_room takes it; a full
      # new time is then offered (:overbook_offered) or booked as an overbook.
      def self.move(original, to_resource:, start_time:, whom:, reason_ien:, remark:, overbook: nil,
                    via: ::RpmsRpc::Scheduling, setup: ::RpmsRpc::SchedulingSetup)
        if start_time == original[:start_time]
          return Result.new(status: :refused, appointment_id: nil,
                            message: "The patient already has an appointment at that time. To move it to another clinic at the same time, cancel it and book again.")
        end

        booking = AppointmentBooking.new(patient_dfn: original[:patient_dfn], start: start_time.strftime("%Y-%m-%dT%H:%M"),
                                         length: length_of(original), note: carried_note(original[:note]))
        booked = AppointmentBookingGateway.book_if_room(booking, to_resource, via: via, setup: setup, overbook: overbook)
        return Result.new(status: booked.status, appointment_id: nil, message: booked.message) unless booked.booked?

        cancelled = AppointmentCancellationGateway.cancel(original[:id], whom: whom, reason_ien: reason_ien, remarks: remark, via: via)
        return Result.new(status: :moved, appointment_id: booked.appointment_id, message: booked.message) if cancelled.cancelled?

        undo(booked.appointment_id, cancelled, whom: whom, reason_ien: reason_ien, via: via)
      end

      # The original's length in minutes.
      def self.length_of(appointment)
        ((appointment[:end_time] - appointment[:start_time]) / 60).round
      end

      # The original's note, as a booking can file it: one line, without the
      # characters a booking note refuses, at most 150 characters.
      def self.carried_note(note)
        text = note.to_s.tr(";:", "  ").squish[0, 150]
        text.length >= 2 ? text : nil
      end

      def self.undo(new_id, refusal, whom:, reason_ien:, via:)
        undone = AppointmentCancellationGateway.cancel(new_id, whom: whom, reason_ien: reason_ien, remarks: UNDO_REMARK, via: via)
        why = refusal.message.presence || "RPMS did not confirm it"
        if undone.cancelled?
          Result.new(status: :refused, appointment_id: nil,
                     message: "The appointment was not moved: the original could not be cancelled (#{why}). It is still booked.")
        else
          Result.new(status: :both, appointment_id: new_id,
                     message: "The new time was booked, but the original could not be cancelled (#{why}), and the new booking could not be undone. The patient now has both. Cancel one of them.")
        end
      end
      private_class_method :undo
    end
  end
end
