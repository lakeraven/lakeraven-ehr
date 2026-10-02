# frozen_string_literal: true

require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/ddr_fileman"

module Lakeraven
  module EHR
    # Booking from the scheduling screen (rpms-ux S-SCH-01, lakeraven-ehr#565).
    #
    # Thin over RpmsRpc::Scheduling.add_appointment, the confirmed BSDX ADD
    # NEW APPOINTMENT write (APPADD^BSDX07 -> $$MAKE^BSDAPI, which files the
    # appointment on the clinic in HOSPITAL LOCATION #44 and on the patient in
    # PATIENT #2.98). The resource is the BSDX RESOURCE name (#9002018.1 .01),
    # which is what the RPC takes; SchedulingGateway.book (the JSON API) passes
    # a clinic IEN there and is left as it is.
    class AppointmentBookingGateway
      UNAVAILABLE = "Scheduling service unavailable"
      CANCELLATION_REASONS_FILE = "409.2"

      class << self
        # Returns { success: true, appointment_id: } or { success: false, status:, error: }.
        def book(resource:, dfn:, start_time:, minutes:, note: nil)
          RpcSupport.with_broker(UNAVAILABLE) do
            result = RpmsRpc::Scheduling.add_appointment(
              patient_dfn: dfn, resource: resource, start_time: start_time,
              end_time: start_time + (minutes.to_i * 60), length_minutes: minutes, note: note
            )
            next { success: false, status: 503, error: UNAVAILABLE } if result.nil?
            next RpcSupport.rejection(result[:error].presence || "Booking rejected") unless result[:success]

            { success: true, appointment_id: result[:appointment_id] }
          end
        end

        # Cancel an appointment (S-SCH-02): the confirmed BSDX CANCEL
        # APPOINTMENT (APPDEL^BSDX08 -> $$CANCEL^BSDAPI). `cancelled_by` is
        # "clinic" or "patient" (the RPC's "C" / "PC"), `reason_ien` a
        # CANCELLATION REASONS (#409.2) entry, `remarks` the user note.
        def cancel(appointment_ien:, cancelled_by:, reason_ien:, remarks: nil)
          type = cancelled_by.to_s == "patient" ? "PC" : "C"
          RpcSupport.with_broker(UNAVAILABLE) do
            result = RpmsRpc::Scheduling.cancel_appointment(appointment_ien, reason: reason_ien, type: type, note: remarks)
            next { success: false, status: 503, error: UNAVAILABLE } if result.nil?
            next RpcSupport.rejection(result[:error].presence || "Cancellation rejected") unless result[:success]

            { success: true }
          end
        end

        # CANCELLATION REASONS (#409.2) for a picker: [{ ien:, name: }], or
        # nil when the broker gave no answer. DDR LISTER by the B (name)
        # index, the same generic listing the tribe picker uses; the file
        # number is the one BSDX CANCEL APPOINTMENT's reason points at.
        def cancellation_reasons
          listed = RpmsRpc::DdrFileman.lister(file: CANCELLATION_REASONS_FILE, xref: "B")
          return nil if listed.nil? || listed[:error]

          listed[:entries].map { |e| { ien: e[:ien].to_i, name: e[:pieces]&.first.to_s } }
        end
      end
    end
  end
end
