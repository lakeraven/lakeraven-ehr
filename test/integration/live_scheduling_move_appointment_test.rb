# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-02.8 to 02.10): the scheduler persona moves an
# appointment on a real RPMS, and what RPMS then holds is read back from
# FileMan: PATIENT (#2.98) and HOSPITAL LOCATION (#44.003). It WRITES, so it
# runs only against a throwaway container and only when asked twice.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_move_appointment_test.rb
class LiveSchedulingMoveAppointmentTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-02.8 the scheduler moves MOUSE,MICKEY M to DEMO PRIMARY CARE: the original is cancelled by the patient with the reason and where it went, the new one carries its note and length" do
    from = clinic_path("DEMO IHS CLINIC")
    to_id = clinic_path("DEMO PRIMARY CARE")[%r{/(\d+)\z}, 1]
    day = weekday_ahead
    time = open_time(from, day)
    note = "live move #{SecureRandom.hex(3)}"
    original = book(from, day, time, length: 30, note: note)

    move = "#{from}/appointments/#{original}/reschedule"
    new_day = day + 1
    new_day += 1 while new_day.saturday? || new_day.sunday?
    get move, params: { date: day.iso8601, to: to_id, on: new_day.iso8601, whom: "PC" }
    assert_response :ok
    new_time = css_select("#reschedule-form label[data-time]").map { |l| l["data-time"] }.select { |t| t >= "13:00" }.sample
    assert new_time, "DEMO PRIMARY CARE has an afternoon time on #{new_day}"
    reason = css_select("#reschedule-form select option").find { |o| o.text == "TRAVEL DIFFICULTY" }&.[]("value")
    assert reason, "a patient-typed reason is offered"

    post move, params: { date: day.iso8601, reschedule: { resource_id: to_id, start: "#{new_day.iso8601}T#{new_time}", whom: "PC", reason_ien: reason, extra: "asked by phone" } }
    assert_response :redirect
    follow_redirect!
    assert_select "#notice", text: /Moved/

    old_at = wall(day, time)
    was = patient_appointment(3, old_at)
    assert_equal "PC", was["3"][:internal], "#2.98 STATUS cancelled by patient"
    assert_equal reason, was["16"][:internal], "#2.98 CANCELLATION REASON"
    assert_match(/\ARescheduled to .* DEMO PRIMARY CARE\. asked by phone\z/, was["17"][:external], "#2.98 CANCELLATION REMARKS")
    assert_equal "208", was["14"][:internal], "#2.98 CANCELLED BY USER is the scheduler"
    assert_empty clinic_appointments(clinic_ien("DEMO IHS CLINIC"), old_at).select { |r| r[:patient] == "3" }, "the original's #44.003 entry is gone"

    new_at = wall(new_day, new_time)
    now = patient_appointment(3, new_at)
    assert_equal clinic_ien("DEMO PRIMARY CARE").to_s, now[".01"][:internal]
    assert_equal "", now["3"][:internal], "#2.98 STATUS of the new one is scheduled"
    entry = clinic_appointments(clinic_ien("DEMO PRIMARY CARE"), new_at).find { |r| r[:patient] == "3" }
    assert entry, "#44.003 holds the new appointment"
    assert_equal [ "30", note ], [ entry[:length], entry[:note] ], "length and note carried"
  end

  test "S-SCH-02.9 and 02.10 a cancelled appointment cannot be moved, and a time RPMS refuses leaves the original booked" do
    from = clinic_path("DEMO IHS CLINIC")
    day = weekday_ahead
    first = open_time(from, day)
    original = book(from, day, first)
    other_time = open_time(from, day, except: first)
    other = book(from, day, other_time)
    move = "#{from}/appointments/#{original}/reschedule"

    # MOUSE already holds the other appointment then, so MAKE^BSDAPI refuses.
    post move, params: { date: day.iso8601, reschedule: { resource_id: from[%r{/(\d+)\z}, 1], start: "#{day.iso8601}T#{other_time}", whom: "C", reason_ien: "7", extra: "" } }
    assert_response :unprocessable_content
    assert_select "#reschedule-alert", text: /already/
    assert_equal "", patient_appointment(3, wall(day, first))["3"][:internal], "the original is still scheduled in #2.98"
    assert(clinic_appointments(clinic_ien("DEMO IHS CLINIC"), wall(day, first)).any? { |r| r[:patient] == "3" }, "and on the clinic in #44.003")

    cancel = "#{from}/appointments/#{other}/cancel"
    post cancel, params: { date: day.iso8601, cancellation: { whom: "C", reason_ien: "7", remarks: "" } }
    get "#{from}/appointments/#{other}/reschedule", params: { date: day.iso8601 }
    assert_response :conflict
  end
end
