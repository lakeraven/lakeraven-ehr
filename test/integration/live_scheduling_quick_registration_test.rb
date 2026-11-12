# frozen_string_literal: true

require "test_helper"

# Live (rpms-ux S-REG-05): a scheduler books a caller who is not on file:
# registers the minimum with a temporary chart number, then books them at the
# time they were booking. It WRITES patients and appointments, so it runs only
# against a throwaway container and only when asked twice: LIVE_RPMS=1 and
# LIVE_RPMS_WRITES=1. Never point it at a shared stack.
#
# PROFILE,SCHED holds SDZREGMENU and AG's AGGRPC context from the build's
# persona seed (openrpms SEEDPERS, lakeraven/openrpms#1056): a scheduler
# mini-registers. An image cut before that seed lacks both, and the first
# assertion below says so.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9110 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_quick_registration_test.rb
class LiveSchedulingQuickRegistrationTest < ActionDispatch::IntegrationTest
  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  # An open time on the clinic's week calendar, from 11:00, a week or so ahead.
  def open_time
    get "/lakeraven-ehr/scheduling"
    clinic = css_select("#resources a").find { |a| a.text == "DEMO IHS CLINIC" }["href"].delete_suffix("/week")
    day = Date.today + 7 + rand(7)
    day += 1 while day.saturday? || day.sunday?
    get "#{clinic}/week", params: { date: day.iso8601 }
    cells = css_select("tr[data-time]").select { |tr| tr["data-time"] >= "11:00" }.filter_map do |tr|
      tr.at_css("td[data-date='#{day.iso8601}'][data-open]:not([data-open='0'])")
    end
    assert cells.any?, "no open time on DEMO IHS CLINIC on #{day}"
    start = Rack::Utils.parse_query(URI(cells.sample.at_css("a[data-book]")["href"]).query)["start"]
    [ clinic, start ]
  end

  test "S-REG-05.1 a caller with no chart is registered with a temporary chart number and booked at the time chosen" do
    clinic, start = open_time
    letters = Array.new(6) { ("A".."Z").to_a.sample }.join
    # A date of birth of its own, so a rerun on the same container is not
    # matched to the caller an earlier run registered.
    dob = (Date.new(1940, 1, 1) + rand(25_000)).iso8601
    name = "ZZCALLER,#{letters}"

    get "#{clinic}/appointments/new", params: { start: start, q: name }
    link = css_select("#quick-register-link").first
    assert link, "no offer to register: PROFILE,SCHED lacks SDZREGMENU (and AGGRPC); the image predates the persona seed that grants them"

    get link["href"]
    assert_response :ok
    token = css_select("#quick-registration-form input[name='submission_id']").first["value"]
    post "#{clinic}/registrations", params: { start: start, length: "15", submission_id: token,
                                              registration: { name: name, sex: "F", dob: dob, ssn: "", no_ssn_reason: "N", chart_number: "" } }

    assert_response :redirect, css_select("[role=alert]").map(&:text).join(" ")
    dfn = response.location[/patient_dfn%5D=(\d+)/, 1]
    follow_redirect!
    assert_select "#quick-registered", text: /Registered #{Regexp.escape(name)}\.\s+Chart number T\d{5}\./
    assert_select "#booking-form input[name='booking[start]'][value='#{start}']"

    post "#{clinic}/appointments", params: { booking: { patient_dfn: dfn, start: start, length: "15", note: "" } }
    assert_response :redirect
    follow_redirect!
    assert_select "#booked"
  end

  test "S-REG-05.3 a caller already on file is offered to book instead, and no second chart is filed" do
    clinic, start, = open_time
    get "#{clinic}/registrations/new", params: { start: start, length: "15" }
    token = css_select("#quick-registration-form input[name='submission_id']").first["value"]
    post "#{clinic}/registrations", params: { start: start, length: "15", submission_id: token,
                                              registration: { name: "MOUSE,MICKEY M", sex: "M", dob: "1910-02-14", ssn: "", no_ssn_reason: "N", chart_number: "" } }

    assert_response :conflict
    assert_select "#possible-matches tr[data-dfn='3'] a[data-book='3']"
  end
end
