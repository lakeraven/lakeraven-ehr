# frozen_string_literal: true

require "test_helper"

# Live (rpms-ux S-SCH-01): the scheduler persona books a patient on a real
# RPMS. It WRITES appointments, so it runs only against a throwaway container
# and only when asked twice: LIVE_RPMS=1 (see test_helper.rb) and
# LIVE_RPMS_WRITES=1. Never point it at a shared stack.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9110 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_scheduling_book_appointment_test.rb
class LiveSchedulingBookAppointmentTest < ActionDispatch::IntegrationTest
  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def weekday_ahead
    day = Date.current + 7 + rand(7)
    day += 1 while day.saturday? || day.sunday?
    day
  end

  test "S-SCH-01.1 and 01.5 the scheduler books MOUSE,MICKEY M into an open time, once" do
    get "/lakeraven-ehr/scheduling"
    assert_response :ok
    link = css_select("#resources a").find { |a| a.text == "DEMO IHS CLINIC" }
    clinic = link["href"]

    day = weekday_ahead
    get clinic, params: { date: day.iso8601 }
    open = css_select("#open-times tr").select { |tr| tr["data-time"].to_s >= "11:00" && tr.at_css("td[data-open]")["data-open"].to_i.positive? }
    time = open.sample["data-time"]
    start = "#{day.iso8601}T#{time}"

    get "#{clinic}/appointments/new", params: { start: start, q: "MOUSE" }
    assert_select "#booking-form label[data-patient='3']"

    post "#{clinic}/appointments", params: { booking: { patient_dfn: "3", start: start, length: "15", note: "" } }
    assert_response :redirect
    follow_redirect!
    assert_select "#booked"
    assert_select "#appointments tr[data-patient='3'] td", text: /\A#{time}/

    post "#{clinic}/appointments", params: { booking: { patient_dfn: "3", start: start, length: "15", note: "" } }
    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /already has appt/
  end

  test "S-SCH-01.12 the front desk, who holds no scheduling key, cannot open scheduling" do
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PREG123", password: "PREG123!!" }
    get "/lakeraven-ehr/scheduling"

    assert_response :forbidden
  end
end
