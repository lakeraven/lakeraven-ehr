# frozen_string_literal: true

require "test_helper"

# Live (rpms-ux S-SCH-03.9, S-SCH-07, S-SCH-08): the scheduler persona
# takes a patient through the day after booking on a real RPMS, and each step
# is read back from FileMan: HOSPITAL LOCATION #44.003 for check-in and
# check-out and PATIENT #2.98 for a no-show. It
# WRITES, so it runs only against a throwaway container and only when asked
# twice: LIVE_RPMS=1 (see test_helper.rb) and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9145 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_visit_day_test.rb
class LiveSchedulingVisitDayTest < ActionDispatch::IntegrationTest
  CLINIC = "DEMO IHS CLINIC"
  PATIENT = 3

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
    get "/lakeraven-ehr/scheduling"
    @clinic = "/lakeraven-ehr/scheduling/clinics/#{RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }[:id]}"
    @duz = RpmsRpc.client.duz.to_s
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-03.9, 07.1, 07.2 and 07.6 the scheduler checks a patient in, undoes it, checks in again, checks out and undoes that" do
    today = Date.today
    row = book_today
    id = row["data-appointment"]
    start = Time.strptime("#{today.iso8601} #{row.at_css('td').text[0, 5]}", "%Y-%m-%d %H:%M")
    checkin_at = Time.now - 600
    path = "#{@clinic}/appointments/#{id}"

    check_in(path, today, checkin_at)
    assert_equal [ fm(checkin_at), @duz, "", "" ], on_clinic(start)

    post "#{path}/checkin/undo", params: { date: today.iso8601 }
    follow_redirect!
    assert_select "#notice", text: /Undid the check-in/
    assert_select "tr[data-appointment='#{id}'] td[data-status='booked']"
    assert_equal [ "", "", "", "" ], on_clinic(start), "S-SCH-03.9: no check-in time or user on #44.003"

    post "#{path}/checkout", params: { date: today.iso8601, checkout: { at: Time.now.strftime("%Y-%m-%dT%H:%M") } }
    assert_response :conflict, "S-SCH-07.2: not checked in, not checked out"

    check_in(path, today, checkin_at)
    left = Time.now
    post "#{path}/checkout", params: { date: today.iso8601, checkout: { at: left.strftime("%Y-%m-%dT%H:%M") } }
    follow_redirect!
    assert_select "tr[data-appointment='#{id}'] td[data-status='checked-out']", text: /Checked out/
    assert_equal [ fm(checkin_at), @duz, fm(left), @duz ], on_clinic(start), "S-SCH-07.1: check-out time and user on #44.003"

    post "#{path}/checkout/undo", params: { date: today.iso8601 }
    follow_redirect!
    assert_select "tr[data-appointment='#{id}'] td[data-status='checked']"
    assert_equal [ fm(checkin_at), @duz, "", "" ], on_clinic(start), "S-SCH-07.6: checked in again"
  end

  test "S-SCH-08.1, 08.2 and 08.4 the scheduler marks a past appointment a no-show and takes it back" do
    day = Date.today - 7
    day -= 1 while day.saturday? || day.sunday?
    start, id = book_in_the_past(day)
    path = "#{@clinic}/appointments/#{id}"

    get @clinic, params: { date: day.iso8601 }
    assert_select "tr[data-appointment='#{id}'] [data-actions] button", text: "No-show"

    post "#{path}/no_show", params: { date: day.iso8601 }
    follow_redirect!
    assert_select "tr[data-appointment='#{id}'] td[data-status='no-show']", text: "No-show"
    assert_equal [ "N", @duz ], on_patient(start), "S-SCH-08.1: #2.98 STATUS no-show, by the scheduler"

    post "#{path}/no_show", params: { date: day.iso8601 }
    assert_response :conflict, "S-SCH-08.2: already a no-show"

    post "#{path}/no_show/undo", params: { date: day.iso8601 }
    follow_redirect!
    assert_select "tr[data-appointment='#{id}'] td[data-status='booked']"
    assert_equal [ "", "" ], on_patient(start), "S-SCH-08.4: #2.98 no longer a no-show"
  end

  private

  def fm(time) = RpmsRpc::FilemanDateParser.to_fileman(time.change(sec: 0)).sub(/0+\z/, "").chomp(".")

  def ciav(&) = RpmsRpc.client.with_context("CIAV VUECENTRIC", &)

  # Books MOUSE into an open time today through the app; the day's row.
  def book_today
    today = Date.today
    get @clinic, params: { date: today.iso8601 }
    open = css_select("#open-times tr[data-time]").select { |tr| tr.at_css("td[data-open]")["data-open"].to_i.positive? }
    open.shuffle.each do |tr|
      time = tr["data-time"]
      post "#{@clinic}/appointments", params: { booking: { patient_dfn: PATIENT.to_s, start: "#{today.iso8601}T#{time}", length: "15", note: "" } }
      next unless response.redirect?

      follow_redirect!
      return css_select("#appointments tr[data-patient='#{PATIENT}']").find { |r| r.at_css("td").text.start_with?(time) && r.at_css("td[data-status='booked']") }
    end
    skip "no open time left today on the throwaway container"
  end

  # A past day's appointment, booked as setup through BSDX (the app books forward only).
  def book_in_the_past(day)
    20.times do
      start = Time.new(day.year, day.month, day.day, 8 + rand(8), [ 0, 15, 30, 45 ].sample)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: CLINIC, start_time: start, end_time: start + 900, length_minutes: 15)
      return [ start, reply[:appointment_id] ] if reply && reply[:success]
    end
    flunk "no time on #{day} took a booking"
  end

  def check_in(path, date, at)
    get "#{path}/checkin", params: { date: date.iso8601, provider_search: "PROFILE" }
    provider = css_select("#checkin-form label[data-provider]").find { |l| l.text.upcase.include?("PROFILE,MD") }["data-provider"]
    post "#{path}/checkin", params: { date: date.iso8601, checkin: { at: at.strftime("%Y-%m-%dT%H:%M"), provider_ien: provider } }
    assert_response :redirect, "checked in: #{response.status} #{css_select("[role='alert']").map(&:text).join(' ').squish}"
  end

  # [309 CHECKED-IN, 302 CHECK IN USER, 303 CHECKED OUT, 304 CHECK OUT USER] on #44.003.
  def on_clinic(start)
    hloc = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }[:hospital_location_id]
    listed = ciav { RpmsRpc::DdrFileman.lister(file: "44.003", iens: ",#{fm(start)},#{hloc},", fields: "@;.01I;309I;302I;303I;304I", flags: "IP", max: "50") }
    row = listed[:entries].find { |e| e[:pieces][0] == PATIENT.to_s } || flunk("no #44.003 entry for DFN #{PATIENT} at #{start}")
    row[:pieces][1, 4].map { |v| v.to_s.sub(/0+\z/, "").chomp(".") }
  end

  # [3 STATUS, 14 NO-SHOW/CANCELLED BY] on PATIENT #2.98.
  def on_patient(start)
    got = ciav { RpmsRpc::DdrFileman.gets_entry(file: "2.98", iens: "#{fm(start)},#{PATIENT},", fields: "3;14", flags: "I") }
    [ got.dig(:fields, "3", :internal).to_s, got.dig(:fields, "14", :internal).to_s ]
  end
end
