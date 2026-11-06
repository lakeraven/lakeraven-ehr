# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-05.2, S-SCH-05.3): the scheduler persona opens a demo
# clinic's day on a real RPMS and sees its hours and its appointments' status.
# It WRITES, so it runs only against a throwaway container and only when asked
# twice.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_clinic_day_test.rb
class LiveSchedulingClinicDayTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  PATIENT = 990_001 # ALPHA,CASEY, a demo patient
  CLINIC = "DEMO IHS CLINIC"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-05.2 and 05.3 a demo day shows its hours, an overbook, and who cancelled" do
    clinic = clinic_path(CLINIC)
    day = weekday_ahead(from: 7, spread: 14)
    first = open_time(clinic, day)
    book(clinic, day, first, dfn: PATIENT)
    book(clinic, day, open_time(clinic, day, except: first), dfn: PATIENT)
    assert RpmsRpc::SchedulingSetup.mark_overbook(hospital_location_id: clinic_ien(CLINIC), start_time: wall(day, first), patient_dfn: PATIENT)[:success]
    LiveRpmsSession.sign_on!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }

    types = access_type_names
    get clinic, params: { date: day.iso8601 }
    assert_response :ok
    rows = css_select("#blocks tbody tr")
    refute_empty rows, "the demo clinic has hours on a weekday"
    rows.each do |row|
      cell = row.at_css("td[data-access-type]")
      assert_equal types.fetch(cell["data-access-type"]), cell.text.strip
      assert_operator row.at_css("td[data-slots]")["data-slots"].to_i, :>, 0
    end

    overbooked = css_select("#appointments tr[data-appointment]").find { |tr| tr.at_css("[data-overbook]") }
    assert overbooked, "the marked appointment shows as an overbook"

    second = css_select("#appointments tr[data-appointment]").reject { |tr| tr.at_css("[data-overbook]") }.first["data-appointment"]
    LiveRpmsSession.sign_on!
    assert RpmsRpc::Scheduling.cancel_appointment(second.to_i, reason: "", type: "PC", note: "live spec")
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
    get clinic, params: { date: day.iso8601 }
    assert_select "#appointment-#{second} [data-status-badge]", text: "Cancelled by the patient"
  end

  private

  def access_type_names
    LiveRpmsSession.sign_on!
    names = RpmsRpc::SchedulingSetup.access_types.to_h { |t| [ t[:id].to_s, t[:name] ] }
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
    names
  end
end
