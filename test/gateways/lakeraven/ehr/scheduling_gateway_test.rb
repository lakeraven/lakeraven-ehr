# frozen_string_literal: true

require "test_helper"

# BPRM twin — scheduling group gateway tests (scenarios #5–#14).
# Gateway logic is exercised against a scripted FakeBroker; the Cucumber
# features stay red pending a live RPMS backend (rpms-ops#366).
module Lakeraven
  module EHR
    class SchedulingGatewayTest < ActiveSupport::TestCase
      include BrokerStubbing

      # --- #5 Book (confirmed: BSDX ADD NEW APPOINTMENT via the gem) --------

      test "book an open slot returns a BSDX appointment id" do
        broker = FakeBroker.new.on("BSDX ADD NEW APPOINTMENT", "7001^")
        use_broker(broker) do
          result = SchedulingGateway.book(15, 42, at: "2026-08-20 09:00", minutes: 20, note: "Follow-up")

          assert result[:success]
          assert_equal 201, result[:status]
          assert_equal 7001, result[:appointment_id]
        end
      end

      test "book sends the confirmed BSDX ADD NEW APPOINTMENT param order via the gem" do
        broker = FakeBroker.new.on("BSDX ADD NEW APPOINTMENT", "7001^")
        use_broker(broker) do
          SchedulingGateway.book(15, 42, at: "2026-08-20 09:00", minutes: 20, note: "Follow-up")

          # START^END^DFN^RESOURCE^LENGTH^NOTE^ACCESS_TYPE^CHART_REQUEST
          assert_equal "BSDX ADD NEW APPOINTMENT", broker.last_call[:rpc]
          assert_equal [ "3260820.0900", "3260820.0920", "42", "15", "20", "Follow-up", "", "" ],
                       broker.last_call[:params]
        end
      end

      test "double-booking an occupied slot is rejected with 409" do
        broker = FakeBroker.new.on("BSDX ADD NEW APPOINTMENT", "0^slot is not available")
        use_broker(broker) do
          result = SchedulingGateway.book(15, 42, at: "2026-08-20 09:00", minutes: 20)

          refute result[:success]
          assert_equal 409, result[:status]
          assert_match(/not available/, result[:error])
        end
      end

      test "booking an unknown clinic is rejected with 422" do
        broker = FakeBroker.new.on("BSDX ADD NEW APPOINTMENT", "0^Clinic not on file")
        use_broker(broker) do
          result = SchedulingGateway.book(999, 42, at: "2026-08-20 09:00", minutes: 20)

          refute result[:success]
          assert_equal 422, result[:status]
          assert_match(/Clinic not on file/, result[:error])
        end
      end

      test "book with a broker-unreachable condition returns 503" do
        broker = FakeBroker.new.raise_with(RpmsRpc::Client::ConnectionError.new("timeout"))
        use_broker(broker) do
          result = SchedulingGateway.book(15, 42, at: "2026-08-20 09:00", minutes: 20)

          assert_equal 503, result[:status]
        end
      end

      # --- #7 Cancel (confirmed: BSDX CANCEL APPOINTMENT via the gem) -------
      # Success is an EMPTY ERRORID column — owned by the gem's cancel semantics.

      test "clinic-cancel an appointment with a reason succeeds" do
        broker = FakeBroker.new.on("BSDX CANCEL APPOINTMENT", [ "" ])
        use_broker(broker) do
          result = SchedulingGateway.cancel(7001, cancel_type: "clinic", reason: "Provider unavailable", note: "Rescheduling")

          assert result[:success]
          # BSDX_APPOINTMENT_IEN^TYPE^REASON^NOTE, as positional gem params.
          assert_equal [ "7001", "C", "Provider unavailable", "Rescheduling" ], broker.last_call[:params]
        end
      end

      test "patient-cancel records the cancelling party and sends the PC type" do
        broker = FakeBroker.new.on("BSDX CANCEL APPOINTMENT", [ "" ])
        use_broker(broker) do
          result = SchedulingGateway.cancel(7001, cancel_type: "patient", reason: "Patient request")

          assert_equal "patient", result[:cancelled_by]
          assert_equal [ "7001", "PC", "Patient request", "" ], broker.last_call[:params]
        end
      end

      test "cancelling an unknown appointment is rejected with 422" do
        broker = FakeBroker.new.on("BSDX CANCEL APPOINTMENT", "Invalid Appointment ID")
        use_broker(broker) do
          result = SchedulingGateway.cancel(999999, cancel_type: "clinic", reason: "Provider unavailable")

          assert_equal 422, result[:status]
          assert_match(/Invalid Appointment ID/, result[:error])
        end
      end

      test "cancellation blocked by another user's lock is 409" do
        broker = FakeBroker.new.on("BSDX CANCEL APPOINTMENT", "Another user is working with this patient")
        use_broker(broker) do
          result = SchedulingGateway.cancel(7001, cancel_type: "clinic", reason: "Provider unavailable")

          assert_equal 409, result[:status]
          assert_match(/Another user/, result[:error])
        end
      end

      test "cancel requires a reason" do
        broker = FakeBroker.new
        use_broker(broker) do
          result = SchedulingGateway.cancel(7001, cancel_type: "clinic", reason: "")

          refute result[:success]
          assert_empty broker.calls
        end
      end

      # --- #8 No-show (confirmed: BSDX NOSHOW via the gem) -----------------
      # The gem owns the INVERTED-polarity ERRORID (result 1 == success).

      test "mark no-show records the no-show status" do
        broker = FakeBroker.new.on("BSDX NOSHOW", "1^")
        use_broker(broker) do
          result = SchedulingGateway.no_show(7001)

          assert result[:success]
          assert_equal "no-show", result[:appointment_status]
          assert_equal [ "7001", "1" ], broker.last_call[:params]
        end
      end

      test "undo no-show clears the flag and returns the appointment to scheduled" do
        broker = FakeBroker.new.on("BSDX NOSHOW", "1^")
        use_broker(broker) do
          result = SchedulingGateway.no_show(7001, undo: true)

          assert_equal "scheduled", result[:appointment_status]
          assert_equal [ "7001", "0" ], broker.last_call[:params]
        end
      end

      test "no-show before the appointment time is rejected with 422" do
        broker = FakeBroker.new.on("BSDX NOSHOW", "0^Cannot no-show before the appointment time")
        use_broker(broker) do
          result = SchedulingGateway.no_show(7001)

          assert_equal 422, result[:status]
          assert_match(/before the appointment time/, result[:error])
        end
      end

      # --- #9 Check-in (confirmed: BSDX CHECKIN APPOINTMENT via the gem) ----
      # "0"/empty ERRORID == success — owned by the gem's check-in semantics.

      test "check in a patient records checked-in status and check-in time" do
        broker = FakeBroker.new.on("BSDX CHECKIN APPOINTMENT", "0")
        use_broker(broker) do
          result = SchedulingGateway.check_in(7001, at: "2026-08-20 08:55")

          assert_equal "checked-in", result[:appointment_status]
          # BSDX_APPOINTMENT_IEN^CHECKIN_DATETIME^CLINIC_CODE^PROVIDER
          assert_equal [ "7001", "3260820.0855", "", "" ], broker.last_call[:params]
        end
      end

      test "undo check-in returns to scheduled (provisional un-check-in path)" do
        broker = FakeBroker.new.on("BSDX CHECKIN APPOINTMENT", "1^")
        use_broker(broker) do
          result = SchedulingGateway.check_in(7001, undo: true)

          assert_equal "scheduled", result[:appointment_status]
          assert_equal [ "7001", "UNDO" ], broker.last_call[:params]
        end
      end

      test "cannot check in a cancelled appointment" do
        broker = FakeBroker.new.on("BSDX CHECKIN APPOINTMENT", "Appointment is cancelled")
        use_broker(broker) do
          result = SchedulingGateway.check_in(7001, at: "2026-08-20 08:55")

          assert_equal 422, result[:status]
          assert_match(/cancelled/, result[:error])
        end
      end

      # --- #10 Rebook (composite) -----------------------------------------

      test "rebook cancels the old slot then books the new one" do
        broker = FakeBroker.new
                           .on("BSDX CANCEL APPOINTMENT", [ "" ])
                           .on("BSDX ADD NEW APPOINTMENT", "7050^")
        use_broker(broker) do
          result = SchedulingGateway.rebook(7001, clinic_ien: 15, at: "2026-08-21 10:00",
                                            reason: "Patient request", dfn: 42, original_at: "2026-08-20 09:00")

          assert result[:success]
          assert_equal 7001, result[:old_appointment_id]
          assert_equal 7050, result[:new_appointment_id]
          assert_equal 1, broker.calls_for("BSDX CANCEL APPOINTMENT").length
          assert_equal 1, broker.calls_for("BSDX ADD NEW APPOINTMENT").length
        end
      end

      test "rebook rolls back the cancel by re-booking the original slot when the new slot is unavailable" do
        broker = FakeBroker.new
                           .on("BSDX CANCEL APPOINTMENT", [ "" ])
                           .on("BSDX ADD NEW APPOINTMENT", "0^slot is not available", "7001^")
        use_broker(broker) do
          result = SchedulingGateway.rebook(7001, clinic_ien: 15, at: "2026-08-21 10:00",
                                            reason: "Patient request", dfn: 42, original_at: "2026-08-20 09:00")

          refute result[:success]
          assert_equal 409, result[:status]
          assert result[:rolled_back]
          # two ADD calls: the failed new booking, then the rollback re-book of the original slot
          add_calls = broker.calls_for("BSDX ADD NEW APPOINTMENT")
          assert_equal 2, add_calls.length
          # the rollback re-books the original slot — its START param is the original datetime
          assert_equal "3260820.0900", add_calls.last[:params].first
        end
      end

      test "rebook with an invalid clinic is refused up front without cancelling the original" do
        broker = FakeBroker.new
                           .on("BSDX CANCEL APPOINTMENT", [ "" ])
                           .on("BSDX ADD NEW APPOINTMENT", "7050^")
        use_broker(broker) do
          result = SchedulingGateway.rebook(7001, clinic_ien: 0, at: "2026-08-21 10:00",
                                            reason: "Patient request", dfn: 42, original_at: "2026-08-20 09:00")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls, "an invalid rebook must never reach the broker — the original stays booked"
        end
      end

      test "rebook with an invalid dfn is refused up front without cancelling the original" do
        broker = FakeBroker.new.on("BSDX CANCEL APPOINTMENT", [ "" ])
        use_broker(broker) do
          result = SchedulingGateway.rebook(7001, clinic_ien: 15, at: "2026-08-21 10:00",
                                            reason: "Patient request", dfn: nil, original_at: "2026-08-20 09:00")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "rebook with an unparseable new time is refused up front without cancelling the original" do
        broker = FakeBroker.new.on("BSDX CANCEL APPOINTMENT", [ "" ])
        use_broker(broker) do
          result = SchedulingGateway.rebook(7001, clinic_ien: 15, at: "not-a-time",
                                            reason: "Patient request", dfn: 42, original_at: "2026-08-20 09:00")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "rebook double failure reports rolled_back false and no restored appointment" do
        # cancel succeeds; the new booking is refused; the rollback re-book of
        # the original slot is refused too — the caller must see that nothing
        # was restored.
        broker = FakeBroker.new
                           .on("BSDX CANCEL APPOINTMENT", [ "" ])
                           .on("BSDX ADD NEW APPOINTMENT", "0^slot is not available", "0^slot is not available")
        use_broker(broker) do
          result = SchedulingGateway.rebook(7001, clinic_ien: 15, at: "2026-08-21 10:00",
                                            reason: "Patient request", dfn: 42, original_at: "2026-08-20 09:00")

          refute result[:success]
          assert_equal 409, result[:status]
          refute result[:rolled_back]
          assert_nil result[:restored_appointment_id]
          assert_equal 2, broker.calls_for("BSDX ADD NEW APPOINTMENT").length
        end
      end

      # --- #5/#9 Write-path time validation --------------------------------

      test "book with an unparseable time is rejected with 422 and never books at server-now" do
        broker = FakeBroker.new.on("BSDX ADD NEW APPOINTMENT", "7001^")
        use_broker(broker) do
          result = SchedulingGateway.book(15, 42, at: "not-a-time", minutes: 20)

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "check-in with an unparseable time is rejected with 422 and never checks in at server-now" do
        broker = FakeBroker.new.on("BSDX CHECKIN APPOINTMENT", "0")
        use_broker(broker) do
          result = SchedulingGateway.check_in(7001, at: "not-a-time")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "check-in with no explicit time still checks in (at the current time)" do
        broker = FakeBroker.new.on("BSDX CHECKIN APPOINTMENT", "0")
        use_broker(broker) do
          result = SchedulingGateway.check_in(7001)

          assert result[:success]
          assert_equal "checked-in", result[:appointment_status]
        end
      end

      # --- #6 Availability -------------------------------------------------

      test "availability returns the open slots the broker computes" do
        broker = FakeBroker.new.on("BSDX GET AVAILABILITY", [ "3260820.0800", "3260820.0820", "3260820.0920" ])
        use_broker(broker) do
          result = SchedulingGateway.availability(15, "2026-08-20")

          times = result[:slots].map { |t| t.strftime("%H:%M") }
          assert_includes times, "08:00"
          refute_includes times, "09:00"
        end
      end

      test "a day with no access blocks has no open slots" do
        broker = FakeBroker.new.on("BSDX GET AVAILABILITY", "")
        use_broker(broker) do
          result = SchedulingGateway.availability(15, "2026-08-21")

          assert_empty result[:slots]
        end
      end

      test "access-block configuration lists configured blocks" do
        broker = FakeBroker.new.on("BSDX ACCESS BLOCKS", [ "ROUTINE^08:00^12:00" ])
        use_broker(broker) do
          result = SchedulingGateway.access_blocks(15)

          block = result[:access_blocks].first
          assert_equal "ROUTINE", block[:name]
          assert_equal "08:00", block[:start_time]
        end
      end

      # --- #11 Clinic schedule --------------------------------------------

      test "clinic schedule lists appointments in time order and excludes cancelled by default" do
        broker = FakeBroker.new.on("BSDX CLINIC SCHEDULE", [
          "7003^3260820.0940^BEGAY,MICHELLE^no-show^44",
          "7001^3260820.0900^RAVEN,NORA^cancelled^42",
          "7002^3260820.0920^RAVEN,NOAH^checked-in^43"
        ])
        use_broker(broker) do
          result = SchedulingGateway.clinic_schedule(15, "2026-08-20")

          names = result[:appointments].map { |a| a[:patient_name] }
          refute_includes names, "RAVEN,NORA"
          assert_equal [ "RAVEN,NOAH", "BEGAY,MICHELLE" ], names
        end
      end

      test "clinic schedule includes cancelled when requested" do
        broker = FakeBroker.new.on("BSDX CLINIC SCHEDULE", [ "7001^3260820.0900^RAVEN,NORA^cancelled^42" ])
        use_broker(broker) do
          result = SchedulingGateway.clinic_schedule(15, "2026-08-20", include_cancelled: true)

          assert_equal "cancelled", result[:appointments].first[:status]
        end
      end

      # --- #12 Patient appointments + routing slip ------------------------

      test "future appointments exclude past and cancelled" do
        broker = FakeBroker.new.on("ORWPT APPTLST", [
          "3260820.0900^15^GENERAL MEDICINE^scheduled",
          "3260902.1330^20^DENTAL^scheduled",
          "3260701.1000^30^BEHAVIORAL HEALTH^cancelled"
        ])
        use_broker(broker) do
          result = SchedulingGateway.patient_appointments(42, as_of: Date.new(2026, 8, 8))

          clinics = result[:appointments].map { |a| a[:clinic] }
          assert_equal [ "GENERAL MEDICINE", "DENTAL" ], clinics.sort.reverse
          assert_equal 2, result[:appointments].length
        end
      end

      test "cancelled appointments returns only cancelled entries" do
        broker = FakeBroker.new.on("ORWPT APPTLST", [
          "3260820.0900^15^GENERAL MEDICINE^scheduled",
          "3260701.1000^30^BEHAVIORAL HEALTH^cancelled"
        ])
        use_broker(broker) do
          result = SchedulingGateway.cancelled_appointments(42)

          assert_equal 1, result[:appointments].length
          assert_equal "BEHAVIORAL HEALTH", result[:appointments].first[:clinic]
        end
      end

      test "routing slip lists the appointments for the given day" do
        broker = FakeBroker.new.on("ORWPT APPTLST", [
          "3260820.0900^15^GENERAL MEDICINE^scheduled",
          "3260902.1330^20^DENTAL^scheduled"
        ])
        use_broker(broker) do
          result = SchedulingGateway.routing_slip(42, "2026-08-20", patient_name: "RAVEN,NORA")

          assert_equal 1, result[:appointments].length
          assert_equal "GENERAL MEDICINE", result[:appointments].first[:clinic]
          assert_equal "RAVEN,NORA", result[:patient_name]
        end
      end

      # --- #13 Waiting list ------------------------------------------------

      test "add to the waiting list files through the safe API and returns the entry id" do
        broker = FakeBroker.new.on("BSDX WAITING LIST ADD", "1^9001")
        use_broker(broker) do
          result = SchedulingGateway.waiting_list_add(15, 42, priority: "routine", reason: "No open slots")

          assert result[:success]
          assert_equal 9001, result[:entry_ien]
          assert_equal "15^42^routine^No open slots", broker.last_call[:params].last
        end
      end

      test "waiting-list add rejects a reason containing the caret delimiter" do
        broker = FakeBroker.new.on("BSDX WAITING LIST ADD", "1^9001")
        use_broker(broker) do
          result = SchedulingGateway.waiting_list_add(15, 42, reason: "No open slots^URGENT")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "waiting-list report lists patients on the list" do
        broker = FakeBroker.new.on("BSDX WAITING LIST",
                                   [ "9001^RAVEN,NORA^42^routine", "9002^BEGAY,MICHELLE^44^routine" ])
        use_broker(broker) do
          result = SchedulingGateway.waiting_list(15)

          assert_equal 2, result[:waiting_list].length
        end
      end

      # --- #14 Availability config + holidays -----------------------------

      test "set availability config files the recurring block" do
        broker = FakeBroker.new.on("BSDX SET AVAILABILITY", "1^")
        use_broker(broker) do
          result = SchedulingGateway.set_availability_config(15, days: %w[Mon Tue Wed Thu Fri],
                                                             start_time: "08:00", end_time: "17:00", minutes: 20)

          assert result[:success]
          assert_equal "15^Mon,Tue,Wed,Thu,Fri^08:00^17:00^20", broker.last_call[:params].last
        end
      end

      test "add a holiday files the date and label" do
        broker = FakeBroker.new.on("BSDX ADD HOLIDAY", "1^")
        use_broker(broker) do
          result = SchedulingGateway.add_holiday(15, "2026-11-26", label: "Thanksgiving")

          assert result[:success]
          assert_equal 201, result[:status]
          assert_equal "15^3261126^Thanksgiving", broker.last_call[:params].last
        end
      end

      test "add a holiday rejects a label containing the caret delimiter" do
        broker = FakeBroker.new.on("BSDX ADD HOLIDAY", "1^")
        use_broker(broker) do
          result = SchedulingGateway.add_holiday(15, "2026-11-26", label: "Thanksgiving^EXTRA")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "add a holiday with an unparseable date is rejected with 422, not a raised 500" do
        broker = FakeBroker.new.on("BSDX ADD HOLIDAY", "1^")
        use_broker(broker) do
          result = SchedulingGateway.add_holiday(15, "not-a-date", label: "Thanksgiving")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "availability with an unparseable date is rejected with 422, not a raised 500" do
        broker = FakeBroker.new.on("BSDX GET AVAILABILITY", "")
        use_broker(broker) do
          result = SchedulingGateway.availability(15, "not-a-date")

          refute result[:success]
          assert_equal 422, result[:status]
          assert_empty broker.calls
        end
      end

      test "remove a holiday files the date" do
        broker = FakeBroker.new.on("BSDX REMOVE HOLIDAY", "1^")
        use_broker(broker) do
          result = SchedulingGateway.remove_holiday(15, "2026-11-26")

          assert result[:success]
          assert_equal "15^3261126", broker.last_call[:params].last
        end
      end
    end
  end
end
