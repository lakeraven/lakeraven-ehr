# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling"

module Lakeraven
  module EHR
    # Booking and checking in a walk-in in one step (rpms-ux S-SCH-06.1), as the
    # Windows scheduler and BPRM do: BSDX ADD NEW APPOINTMENT with the access
    # type "WALKIN" (APPADD^BSDX07 files #2.98 PURPOSE OF VISIT 4 and BSDX
    # APPOINTMENT WALKIN), at the current slot of the clinic's grid for one slot
    # length, then BSDX CHECKIN APPOINTMENT, which files the check-in and the
    # visit.
    #
    # The walk-in is booked under the same per-day lock and room check as any
    # booking, so a full or closed time is refused (S-SCH-06.2) and nothing is
    # filed. If RPMS refuses the check-in, the booking just made is cancelled
    # again (CANCEL^BSDAPI's default reason), so no walk-in is left waiting
    # unchecked; the result says so.
    class AppointmentWalkInGateway
      Result = Data.define(:status, :appointment_id, :message) do
        def checked_in? = status == :checked_in
      end

      UNDO_REMARK = "Walk-in not checked in. Booking undone"

      def self.book_and_check_in(walk_in, resource, provider_ien:, stop_ien:, overbook: nil, via: ::RpmsRpc::Scheduling, setup: ::RpmsRpc::SchedulingSetup)
        booking = AppointmentBooking.new(patient_dfn: walk_in.patient_dfn, start: slot_start(walk_in.time, resource).strftime("%Y-%m-%dT%H:%M"),
                                         length: resource[:time_scale])
        booked = AppointmentBookingGateway.book_if_room(booking, resource, via: via, setup: setup, access_type: "WALKIN", overbook: overbook)
        return Result.new(status: booked.status, appointment_id: nil, message: booked.message) unless booked.booked?

        id = booked.appointment_id
        checked = AppointmentCheckinGateway.check_in(
          id, at: walk_in.time, provider_ien: provider_ien, clinic_code: stop_ien, via: via,
              reread: -> { AppointmentBookingGateway.appointment(resource, id, walk_in.time.to_date, via: via) }
        )
        return Result.new(status: :checked_in, appointment_id: id, message: [ booked.message, visit_warning(checked.message) ].compact.join(" ").presence) if checked.checked_in?

        undo(id, checked, via: via)
      end

      # Whether the resource's clinic uses several clinic stop codes, so the
      # check-in must name one: CLINIC SETUP PARAMETERS (#9009017.2) MULTIPLE
      # CLINIC CODES USED?, by BSDX CLINIC SETUP.
      def self.several_stops?(resource, via: ::RpmsRpc::Scheduling)
        setup = Array(via.clinic_setup).find { |c| c[:location_ien].to_i == resource[:hospital_location_id].to_i }
        setup.present? && setup[:multiple_clinic_codes].to_s.upcase.start_with?("Y")
      end

      # The clinic stops a check-in may name: CLINIC STOP (#40.7) .01 NAME,
      # 1 AMIS REPORTING STOP CODE, 2 INACTIVE DATE (none, or later than today).
      # Read with DDR LISTER in the sign-on context, as the cancellation
      # reasons are. A failed read is an empty list, which the form says.
      def self.stops(via: ::RpmsRpc::DdrFileman)
        listing = via.lister(file: "40.7", fields: "@;.01;1;2I", xref: "B")
        return [] if listing.nil? || listing[:error]

        today = ::RpmsRpc::FilemanDateParser.to_fileman(Date.today).to_i
        listing[:entries].filter_map do |entry|
          name, code, inactive = entry[:pieces]
          next if inactive.to_s.present? && inactive.to_i <= today

          { ien: entry[:ien].to_i, name: name, code: code }
        end
      end

      # The start of the grid slot the time falls in: the clinic's day is cut
      # into slots of its time scale from midnight, as the scheduling client
      # draws it.
      def self.slot_start(time, resource)
        scale = [ resource[:time_scale].to_i, 1 ].max
        minutes = (time.hour * 60) + time.min
        floor = minutes - (minutes % scale)
        Time.new(time.year, time.month, time.day, floor / 60, floor % 60)
      end

      def self.visit_warning(message)
        "RPMS filed the check-in but reported: #{message} Check the visit." if message.present?
      end
      private_class_method :visit_warning

      def self.undo(id, refusal, via:)
        why = refusal.message.presence || "RPMS did not confirm it"
        undone = AppointmentCancellationGateway.cancel(id, whom: "C", reason_ien: nil, remarks: UNDO_REMARK, via: via)
        if undone.cancelled?
          Result.new(status: :refused, appointment_id: nil, message: "The walk-in was not checked in (#{why}), so it was not booked either.")
        else
          Result.new(status: :booked_only, appointment_id: id,
                     message: "The walk-in was booked but not checked in (#{why}). Check the patient in from the clinic's day, or cancel the booking.")
        end
      end
      private_class_method :undo
    end
  end
end
