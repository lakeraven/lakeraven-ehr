# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-05.5): the scheduler persona lists the appointments across
# their clinics on a real RPMS. It WRITES, so it runs only against a throwaway
# container and only when asked twice.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_appointment_list_test.rb
class LiveSchedulingAppointmentListTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  PATIENT = 990_001 # ALPHA,CASEY, a demo patient
  LIST = "/lakeraven-ehr/scheduling/appointments"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-05.5 a checked-in appointment is listed under checked in, and not under booked" do
    clinic = clinic_path("DEMO IHS CLINIC")
    day = weekday_ahead(from: 7, spread: 14)
    id = book(clinic, day, open_time(clinic, day), dfn: PATIENT)

    get LIST, params: { when: "future", status: "booked" }
    assert_response :ok
    assert_select "#appointment-list tr[data-appointment='#{id}'] td[data-status='booked']"

    LiveRpmsSession.sign_on!
    RpmsRpc::Scheduling.checkin_appointment(id, checkin_time: Time.now)
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }

    get LIST, params: { when: "future", status: "checked", sort: "checkin" }
    assert_select "#appointment-list tr[data-appointment='#{id}'] td[data-status='checked']"
    get LIST, params: { when: "future", status: "booked" }
    assert_select "#appointment-list tr[data-appointment='#{id}']", 0
  end
end
