# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-09): the scheduler persona corrects a booked
# appointment's note and length and a cancelled one's remarks on a real RPMS,
# read back from FileMan. It WRITES, so it runs only against a throwaway
# container and only when asked twice.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_appointment_details_test.rb
class LiveSchedulingAppointmentDetailsTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-09.1, 09.3 and 09.4 the scheduler changes a note and a length, then a cancellation's remarks" do
    clinic = clinic_path("DEMO IHS CLINIC")
    day = weekday_ahead(from: 21, spread: 30)
    time = open_time(clinic, day)
    id = book(clinic, day, time, note: "first note")
    details = "#{clinic}/appointments/#{id}/details"

    get details, params: { date: day.iso8601 }
    assert_select "#details-form input[name='details[length]']", 1, "DEMO IHS CLINIC allows variable lengths"
    post details, params: { date: day.iso8601, details: { note: "second note", length: "30" } }
    assert_response :redirect, flash[:alert].to_s

    entry = clinic_appointments(clinic_ien("DEMO IHS CLINIC"), wall(day, time)).find { |r| r[:patient] == "3" }
    assert_equal [ "30", "second note" ], [ entry[:length], entry[:note] ], "#44.003 LENGTH OF APP'T and OTHER"
    follow_redirect!
    assert_select "#appointments tr[data-appointment='#{id}'] td", text: /\A#{time}.#{(wall(day, time) + 1800).strftime('%H:%M')}/

    post "#{clinic}/appointments/#{id}/cancel", params: { date: day.iso8601, cancellation: { whom: "C", reason_ien: "7", remarks: "first remarks" } }
    assert_response :redirect
    post details, params: { date: day.iso8601, details: { remarks: "corrected remarks" } }
    assert_response :redirect, flash[:alert].to_s
    assert_equal "corrected remarks", patient_appointment(3, wall(day, time))["17"][:external], "#2.98 CANCELLATION REMARKS"
  end
end
