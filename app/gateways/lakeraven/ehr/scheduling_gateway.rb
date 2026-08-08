# frozen_string_literal: true

require "rpms_rpc/api/scheduling"

module Lakeraven
  module EHR
    # BPRM twin — scheduling group (scenarios #5–#14).
    #
    # The four confirmed BSDX writes (book / cancel / no-show / check-in) are
    # delegated to the gem's RpmsRpc::Scheduling wrappers, which are grounded in
    # the live #8994 registry dump (rpms-rpc#171). The gem owns the RPC names,
    # the BSDX param order, and the two awkward response semantics the gateway
    # used to re-implement (and got wrong):
    #   * BSDX NOSHOW's ERRORID column is an INVERTED success flag (1 == ok).
    #   * BSDX CANCEL/UNCANCEL signal success with an EMPTY ERRORID column.
    # This gateway now only adapts the gem's {success:, ...}/nil result into the
    # engine's transport-neutral Hash (with an HTTP :status). A nil gem result
    # means "broker gave no answer" → 503, distinct from a broker rejection.
    #
    # The remaining report/config methods still target BSDX RPCs that are NOT in
    # the #8994 dump; they are marked PROVISIONAL until a trace capture confirms
    # the name + encoding. patient/routing reads go through ORWPT APPTLST, a
    # confirmed stock RPC.
    #
    # See docs/BPRM_REG_SCHED_TWIN.md for the scenario→RPC mapping.
    class SchedulingGateway
      # Confirmed stock read (ORWPT APPTLST) used by the patient/routing reads.
      APPTLST_RPC = "ORWPT APPTLST"

      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      AVAILABILITY_RPC = "BSDX GET AVAILABILITY"
      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      ACCESS_BLOCK_RPC = "BSDX ACCESS BLOCKS"
      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      SCHEDULE_RPC = "BSDX CLINIC SCHEDULE"
      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      ROUTING_RPC = "BSDX ROUTING SLIP"
      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      WAITLIST_RPC = "BSDX WAITING LIST"
      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      WAITLIST_ADD_RPC = "BSDX WAITING LIST ADD"
      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      CONFIG_RPC = "BSDX SET AVAILABILITY"
      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      ADD_HOLIDAY_RPC = "BSDX ADD HOLIDAY"
      # PROVISIONAL: RPC name/encoding unconfirmed against #8994 — needs trace capture.
      DEL_HOLIDAY_RPC = "BSDX REMOVE HOLIDAY"
      # PROVISIONAL: no stock un-check-in RPC exists in #8994. BSDX CHECKIN with
      # an "UNDO" flag is a placeholder encoding pending trace capture; the
      # confirmed BSDX CHECKIN APPOINTMENT (via the gem) has no undo path.
      UNCHECKIN_RPC = "BSDX CHECKIN APPOINTMENT"

      UNAVAILABLE = "Scheduling service unavailable"
      # BSDX cancellation TYPE codes: clinic-cancelled "C" / patient-cancelled "PC".
      CANCEL_TYPES = { "clinic" => "C", "patient" => "PC" }.freeze

      class << self
        # --- #5 Book an appointment (POST /clinics/:ien/appointments) -------
        # Confirmed: RpmsRpc::Scheduling.add_appointment → BSDX ADD NEW
        # APPOINTMENT → $$MAKE^BSDAPI (^SC + ^BSDXAPPT / 9002018.4). The clinic
        # is passed through as the BSDX RESOURCE; end time is derived from the
        # requested length.
        def book(clinic_ien, dfn, at:, minutes:, note: nil)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)
          return validation_error("dfn is required") unless valid_id?(dfn)

          start = parse_time(at)
          return validation_error("appointment time is invalid") unless start

          RpcSupport.with_broker(UNAVAILABLE) do
            result = RpmsRpc::Scheduling.add_appointment(
              patient_dfn: dfn, resource: clinic_ien, start_time: start,
              end_time: start + (minutes.to_i * 60), length_minutes: minutes, note: note
            )
            next scheduling_rejection(result, "Booking rejected") unless accepted?(result)

            { success: true, status: 201, appointment_id: result[:appointment_id],
              clinic_ien: clinic_ien.to_i, dfn: dfn.to_i, at: at }
          end
        end

        # --- #7 Cancel an appointment (POST /appointments/:id/cancel) -------
        # Confirmed: RpmsRpc::Scheduling.cancel_appointment → BSDX CANCEL
        # APPOINTMENT → $$CANCEL^BSDAPI. Empty-ERRORID==success handled by the gem.
        def cancel(appointment_id, cancel_type:, reason:, note: nil)
          return validation_error("appointment id is required") unless valid_id?(appointment_id)
          return validation_error("reason is required") if blank?(reason)

          code = CANCEL_TYPES.fetch(cancel_type.to_s, "C")
          RpcSupport.with_broker(UNAVAILABLE) do
            result = RpmsRpc::Scheduling.cancel_appointment(appointment_id, reason: reason, type: code, note: note)
            next scheduling_rejection(result, "Cancellation rejected") unless accepted?(result)

            { success: true, status: 200, appointment_id: appointment_id.to_i, cancelled_by: cancel_type.to_s }
          end
        end

        # --- #8 No-show (POST /appointments/:id/no_show, DELETE to undo) ----
        # Confirmed: RpmsRpc::Scheduling.mark_no_show → BSDX NOSHOW. The gem owns
        # the INVERTED-polarity ERRORID (1 == success) and the set/clear flag.
        def no_show(appointment_id, undo: false)
          return validation_error("appointment id is required") unless valid_id?(appointment_id)

          RpcSupport.with_broker(UNAVAILABLE) do
            result = RpmsRpc::Scheduling.mark_no_show(appointment_id, no_show: !undo)
            next scheduling_rejection(result, "No-show rejected") unless accepted?(result)

            { success: true, status: 200, appointment_id: appointment_id.to_i,
              appointment_status: undo ? "scheduled" : "no-show" }
          end
        end

        # --- #9 Check-in (POST /appointments/:id/check_in, /undo_check_in) --
        # Confirmed: RpmsRpc::Scheduling.checkin_appointment → BSDX CHECKIN
        # APPOINTMENT ("0"/empty ERRORID == success, handled by the gem). Undo
        # has no stock RPC and stays on the PROVISIONAL placeholder below.
        def check_in(appointment_id, at: nil, undo: false)
          return validation_error("appointment id is required") unless valid_id?(appointment_id)
          return uncheck_in(appointment_id) if undo

          # An omitted time means "check in now"; a PROVIDED but unparseable
          # time is a caller error and must never silently become server-now.
          checkin_time = at.nil? ? Time.now : parse_time(at)
          return validation_error("check-in time is invalid") unless checkin_time

          RpcSupport.with_broker(UNAVAILABLE) do
            result = RpmsRpc::Scheduling.checkin_appointment(appointment_id, checkin_time: checkin_time)
            next scheduling_rejection(result, "Check-in rejected") unless accepted?(result)

            { success: true, status: 200, appointment_id: appointment_id.to_i, appointment_status: "checked-in" }
          end
        end

        # --- #10 Rebook (POST /appointments/:id/rebook) --------------------
        # Composite: cancel then book. EVERY input the book leg needs is
        # validated BEFORE the cancel fires — the cancel is irreversible from
        # here except by re-booking, and a rollback with the same invalid
        # clinic/dfn/time would fail the same way, stranding the patient with
        # no appointment. If the (validated) new slot is still refused by the
        # broker, the cancel is rolled back by re-booking the original slot.
        def rebook(appointment_id, clinic_ien:, at:, reason:, dfn:, minutes: 20, original_at:)
          return validation_error("appointment id is required") unless valid_id?(appointment_id)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)
          return validation_error("dfn is required") unless valid_id?(dfn)
          return validation_error("appointment time is invalid") unless parse_time(at)

          cancelled = cancel(appointment_id, cancel_type: "clinic", reason: reason)
          return cancelled unless cancelled[:success]

          booked = book(clinic_ien, dfn, at: at, minutes: minutes)
          return rollback_rebook(clinic_ien, dfn, original_at, minutes, booked) unless booked[:success]

          { success: true, status: 200, old_appointment_id: appointment_id.to_i, new_appointment_id: booked[:appointment_id] }
        end

        # --- #6 Availability (GET /clinics/:ien/availability) --------------
        # PROVISIONAL: unconfirmed against #8994. The confirmed gem read is
        # RpmsRpc::Scheduling.availability (BSDX SEARCH AVAILABILITY), which
        # returns availability *blocks* per resource — not the computed open
        # slots this endpoint returns — so it is not a drop-in and awaits a
        # trace capture of the open-slot RPC.
        def availability(clinic_ien, date)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)
          return validation_error("date is invalid") unless RpcSupport.valid_fm_date?(date)

          RpcSupport.with_broker(UNAVAILABLE) do
            raw = RpcSupport.broker.call_rpc(AVAILABILITY_RPC, clinic_ien.to_s, RpcSupport.fm_date(date))
            slots = RpcSupport.lines(raw).filter_map { |l| parse_slot(l) }
            { success: true, status: 200, slots: slots }
          end
        end

        # --- #6 Access-block configuration (read) --------------------------
        # PROVISIONAL: unconfirmed against #8994 — needs trace capture.
        def access_blocks(clinic_ien)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)

          RpcSupport.with_broker(UNAVAILABLE) do
            raw = RpcSupport.broker.call_rpc(ACCESS_BLOCK_RPC, clinic_ien.to_s)
            { success: true, status: 200, access_blocks: RpcSupport.lines(raw).filter_map { |l| parse_access_block(l) } }
          end
        end

        # --- #11 Clinic day schedule (GET /clinics/:ien/schedule) ----------
        # PROVISIONAL: unconfirmed against #8994 — needs trace capture.
        def clinic_schedule(clinic_ien, date, include_cancelled: false)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)
          return validation_error("date is invalid") unless RpcSupport.valid_fm_date?(date)

          RpcSupport.with_broker(UNAVAILABLE) do
            raw = RpcSupport.broker.call_rpc(SCHEDULE_RPC, clinic_ien.to_s, RpcSupport.fm_date(date))
            appts = RpcSupport.lines(raw).filter_map { |l| parse_schedule_row(l) }
            appts = appts.reject { |a| a[:status] == "cancelled" } unless include_cancelled
            { success: true, status: 200, appointments: appts.sort_by { |a| a[:time].to_s } }
          end
        end

        # --- #12 A patient's future / cancelled appointments ---------------
        # Confirmed stock read: ORWPT APPTLST.
        def patient_appointments(dfn, as_of: Date.today)
          appointments_for(dfn) { |appts| future(appts, as_of) }
        end

        def cancelled_appointments(dfn)
          appointments_for(dfn) { |appts| appts.select { |a| a[:status] == "cancelled" } }
        end

        # --- #12 Routing slip (GET /patients/:dfn/routing_slip) ------------
        # Confirmed stock read: ORWPT APPTLST, filtered to the requested day.
        def routing_slip(dfn, date, patient_name: nil)
          return validation_error("dfn is required") unless valid_id?(dfn)

          RpcSupport.with_broker(UNAVAILABLE) do
            wanted = safe_date(date)
            raw = RpcSupport.broker.call_rpc(APPTLST_RPC, dfn.to_s)
            appts = RpcSupport.lines(raw).filter_map { |l| parse_appt_row(l) }
            on_day = appts.select { |a| a[:datetime].respond_to?(:to_date) && a[:datetime].to_date == wanted }
            { success: true, status: 200, patient_name: patient_name, date: wanted, appointments: on_day }
          end
        end

        # --- #13 Waiting list report (GET /clinics/:ien/waiting_list) ------
        # PROVISIONAL: unconfirmed against #8994 — needs trace capture.
        def waiting_list(clinic_ien)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)

          RpcSupport.with_broker(UNAVAILABLE) do
            raw = RpcSupport.broker.call_rpc(WAITLIST_RPC, clinic_ien.to_s)
            { success: true, status: 200, waiting_list: RpcSupport.lines(raw).filter_map { |l| parse_waitlist_row(l) } }
          end
        end

        # --- #13 Add to the waiting list (POST /clinics/:ien/waiting_list) -
        # PROVISIONAL: unconfirmed against #8994 — needs trace capture. Must
        # ultimately file through the BSDWL API / ^DIE, never a raw global set.
        def waiting_list_add(clinic_ien, dfn, priority: "routine", reason: nil)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)
          return validation_error("dfn is required") unless valid_id?(dfn)
          if [ priority, reason ].any? { |v| RpcSupport.unsafe_field?(v) }
            return validation_error("waiting-list fields contain unsupported characters")
          end

          RpcSupport.with_broker(UNAVAILABLE) do
            payload = [ clinic_ien, dfn, priority, reason ].map(&:to_s).join("^")
            parts = RpcSupport.pieces(RpcSupport.broker.call_rpc(WAITLIST_ADD_RPC, clinic_ien.to_s, payload))
            next RpcSupport.rejection(parts[1] || "Waiting-list add rejected") unless RpcSupport.success_flag?(parts)

            { success: true, status: 201, entry_ien: parts[1].to_i, clinic_ien: clinic_ien.to_i, dfn: dfn.to_i }
          end
        end

        # --- #14 Availability config + holidays (admin) --------------------
        # PROVISIONAL: unconfirmed against #8994 — needs trace capture. Config
        # writes must file through the scheduling API / ^DIE on BSDX ACCESS
        # BLOCK (9002018.3) + ACCESS TYPE (9002018.35), never a raw global set.
        def set_availability_config(clinic_ien, days:, start_time:, end_time:, minutes:)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)
          if [ *Array(days), start_time, end_time ].any? { |v| RpcSupport.unsafe_field?(v) }
            return validation_error("availability fields contain unsupported characters")
          end

          RpcSupport.with_broker(UNAVAILABLE) do
            payload = [ clinic_ien, Array(days).join(","), start_time, end_time, minutes ].map(&:to_s).join("^")
            parts = RpcSupport.pieces(RpcSupport.broker.call_rpc(CONFIG_RPC, clinic_ien.to_s, payload))
            next RpcSupport.rejection(parts[1] || "Config rejected") unless RpcSupport.success_flag?(parts)

            { success: true, status: 200, clinic_ien: clinic_ien.to_i }
          end
        end

        # PROVISIONAL: unconfirmed against #8994 — needs trace capture.
        def add_holiday(clinic_ien, date, label:)
          return validation_error("label contains unsupported characters") if RpcSupport.unsafe_field?(label)

          holiday_write(ADD_HOLIDAY_RPC, clinic_ien, date, [ label ], status: 201)
        end

        # PROVISIONAL: unconfirmed against #8994 — needs trace capture.
        def remove_holiday(clinic_ien, date)
          holiday_write(DEL_HOLIDAY_RPC, clinic_ien, date, [], status: 200)
        end

        private

        # PROVISIONAL placeholder — see UNCHECKIN_RPC. No confirmed un-check-in RPC.
        def uncheck_in(appointment_id)
          RpcSupport.with_broker(UNAVAILABLE) do
            parts = RpcSupport.pieces(RpcSupport.broker.call_rpc(UNCHECKIN_RPC, appointment_id.to_s, "UNDO"))
            next RpcSupport.rejection(parts[1] || "Undo check-in rejected") unless RpcSupport.success_flag?(parts)

            { success: true, status: 200, appointment_id: appointment_id.to_i, appointment_status: "scheduled" }
          end
        end

        # A gem write result is "accepted" only when it is a Hash reporting
        # success. nil (no broker answer) and {success:false} both fall through
        # to scheduling_rejection.
        def accepted?(result)
          result.is_a?(Hash) && result[:success]
        end

        # Map a non-accepted gem result onto a transport-neutral failure:
        #   nil                     → 503 (broker gave no answer / unreachable)
        #   { success:false, error} → 409/422 via RpcSupport.rejection
        def scheduling_rejection(result, default_message)
          return { success: false, status: 503, error: UNAVAILABLE } if result.nil?

          message = result[:error].to_s
          RpcSupport.rejection(message.empty? ? default_message : message)
        end

        # The date is FileMan-encoded HERE, after validation — an unparseable
        # date returns 422 instead of raising past with_broker as a 500.
        def holiday_write(rpc, clinic_ien, date, extra_parts, status:)
          return validation_error("clinic is required") unless valid_id?(clinic_ien)
          return validation_error("date is invalid") unless RpcSupport.valid_fm_date?(date)

          RpcSupport.with_broker(UNAVAILABLE) do
            payload_parts = [ clinic_ien, RpcSupport.fm_date(date), *extra_parts ]
            parts = RpcSupport.pieces(RpcSupport.broker.call_rpc(rpc, clinic_ien.to_s, payload_parts.map(&:to_s).join("^")))
            next RpcSupport.rejection(parts[1] || "Holiday change rejected") unless RpcSupport.success_flag?(parts)

            { success: true, status: status, clinic_ien: clinic_ien.to_i }
          end
        end

        def rollback_rebook(clinic_ien, dfn, original_at, minutes, booked)
          restored = book(clinic_ien, dfn, at: original_at, minutes: minutes)
          {
            success: false, status: booked[:status], error: booked[:error],
            rolled_back: restored[:success], restored_appointment_id: restored[:appointment_id]
          }
        end

        def appointments_for(dfn, as_of: nil)
          return validation_error("dfn is required") unless valid_id?(dfn)

          RpcSupport.with_broker(UNAVAILABLE) do
            raw = RpcSupport.broker.call_rpc(APPTLST_RPC, dfn.to_s)
            appts = RpcSupport.lines(raw).filter_map { |l| parse_appt_row(l) }
            { success: true, status: 200, appointments: yield(appts) }
          end
        end

        def future(appts, as_of)
          cutoff = safe_date(as_of)
          appts.reject { |a| a[:status] == "cancelled" }
               .select { |a| a[:datetime].respond_to?(:to_date) && a[:datetime].to_date >= cutoff }
        end

        def parse_slot(line)
          parts = line.to_s.split("^", -1)
          return nil if parts[0].to_s.empty?

          RpmsRpc::FilemanDateParser.parse_datetime(parts[0])
        end

        def parse_access_block(line)
          parts = line.to_s.split("^", -1)
          return nil if parts[0].to_s.empty?

          { name: parts[0], start_time: parts[1], end_time: parts[2] }
        end

        def parse_schedule_row(line)
          parts = line.to_s.split("^", -1)
          return nil if parts[0].to_s.empty?

          {
            appointment_id: parts[0].to_i, time: RpmsRpc::FilemanDateParser.parse_datetime(parts[1]),
            patient_name: parts[2], status: parts[3], dfn: parts[4].to_i
          }
        end

        def parse_appt_row(line)
          parts = line.to_s.split("^", -1)
          return nil if parts[0].to_s.empty?

          {
            datetime: RpmsRpc::FilemanDateParser.parse_datetime(parts[0]),
            clinic_ien: parts[1].to_i, clinic: parts[2], status: normalize_status(parts[3])
          }
        end

        def parse_waitlist_row(line)
          parts = line.to_s.split("^", -1)
          return nil if parts[0].to_s.empty?

          { entry_ien: parts[0].to_i, patient_name: parts[1], dfn: parts[2].to_i, priority: parts[3] }
        end

        def normalize_status(raw)
          raw.to_s.strip.downcase.empty? ? "scheduled" : raw.to_s.strip.downcase
        end

        # Write-path time parsing: an unparseable value returns nil so the
        # caller can 422 — it must NEVER be silently coerced to Time.now,
        # which would book/check-in at server-now instead of the asked time.
        def parse_time(value)
          return value if value.is_a?(Time)

          Time.parse(value.to_s)
        rescue ArgumentError, TypeError
          nil
        end

        def safe_date(value)
          value.is_a?(Date) ? value : Date.parse(value.to_s)
        rescue ArgumentError, TypeError
          Date.today
        end

        def valid_id?(value)
          !value.nil? && value.to_s.strip != "" && value.to_i.positive?
        end

        def blank?(value)
          value.nil? || value.to_s.strip.empty?
        end

        def validation_error(message)
          { success: false, status: 422, error: message }
        end
      end
    end
  end
end
