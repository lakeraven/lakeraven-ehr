# frozen_string_literal: true

require "rpms_rpc/api/scheduling"

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
      end
    end
  end
end
