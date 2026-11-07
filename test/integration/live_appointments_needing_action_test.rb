# frozen_string_literal: true

require "test_helper"

# Live (#875, rpms-ux S-SCH-13.5): the scheduler lists the appointments in
# their clinics past their time with no check-in, check-out, cancellation or
# no-show recorded, and the dashboard counts today's. On a real RPMS the
# scheduler persona books a past day's appointments into DEMO IHS CLINIC and
# takes each but one through the app to a recorded state: checked in, checked
# out, cancelled, a no-show. The list for that day must be exactly what RPMS's
# own Appointments Requiring Action report (BSDAMR2) would list for the
# clinic: every patient booked at the clinic that day (HOSPITAL LOCATION
# #44.003) whose PATIENT #2.98 CURRENT STATUS is empty or NO ACTION TAKEN.
#
# Past and earlier-today appointments are booked through BSDX ADD NEW
# APPOINTMENT as setup (the app books forward only). It WRITES, so it runs only
# against a throwaway container and only when asked twice: LIVE_RPMS=1 (see
# test_helper.rb) and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9175 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_appointments_needing_action_test.rb
class LiveAppointmentsNeedingActionTest < ActionDispatch::IntegrationTest
  CLINIC = "DEMO IHS CLINIC"
  PATIENT = 3
  LIST = "/lakeraven-ehr/scheduling/needing_action"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
    assert_response :redirect, "signed on as the scheduler"
    @resource = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }
    @clinic = "/lakeraven-ehr/scheduling/clinics/#{@resource[:id]}"
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-13.5 the list over a past day is exactly the clinic's appointments with no action recorded, as RPMS's own report finds them" do
    day = Date.today - 14
    day -= 1 while day.saturday? || day.sunday?
    untouched, checked_in, checked_out, cancelled, no_show = Array.new(5) { book(day) }
    check_in(checked_in, day)
    check_in(checked_out, day)
    check_out(checked_out, day)
    cancel(cancelled, day)
    post "#{@clinic}/appointments/#{no_show[:id]}/no_show", params: { date: day.iso8601 }
    assert_response :redirect, "marked a no-show"

    get LIST, params: { from: day.iso8601, to: day.iso8601 }
    assert_response :ok
    rows = listed.select { |r| r[:resource] == @resource[:id].to_s }

    assert_includes rows.map { |r| r[:id] }, untouched[:id].to_s, "the appointment left untouched is listed"
    [ checked_in, checked_out, cancelled, no_show ].each do |handled|
      assert_not_includes rows.map { |r| r[:id] }, handled[:id].to_s, "the one #{handled[:state]} is not"
    end
    assert_equal no_action_on_clinic(day).sort, rows.map { |r| [ r[:start], r[:patient] ] }.sort,
      "exactly the patients RPMS's report (BSDAMR2) would list at #{CLINIC} on #{day}"
    assert_equal [ "#{@clinic}?date=#{day.iso8601}#appointment-#{untouched[:id]}" ],
      css_select("#needing-action tr[data-appointment='#{untouched[:id]}'] a").map { |a| a["href"] }, "the row opens the clinic's day"
  end

  test "S-SCH-13.5 the dashboard counts today's: the untouched past one, not the checked-in one or the one still to come" do
    now = Time.now
    skip "too early in the day for past times" if now.hour < 2
    midnight = Date.today.to_time
    before = dashboard_count

    untouched = book(Date.today, between: midnight..(now - 3600))
    checked_in = book(Date.today, between: midnight..(now - 3600))
    check_in(checked_in, Date.today)
    later = book(Date.today, between: (now + 3600)..(midnight + 85_500)) if now.hour < 22

    count = dashboard_count
    assert_equal before + 1, count, "the untouched past appointment counts, the checked-in one and the one still to come do not"

    get css_select("#needing-action-count a").first["href"]
    assert_response :ok
    assert_equal count, listed.size, "the count is the default list's length"
    assert_equal [ Date.today.iso8601 ] * 2, [ css_select("#from").first["value"], css_select("#to").first["value"] ], "the default window is today"
    ids = listed.map { |r| r[:id] }
    assert_includes ids, untouched[:id].to_s
    assert_not_includes ids, checked_in[:id].to_s
    assert_not_includes ids, later[:id].to_s if later
  end

  test "S-SCH-13.8 a user who does not schedule sees no count, and the list refuses them" do
    post "/lakeraven-ehr/login", params: { username: "PMD123", password: "PMD123!!" }
    assert_response :redirect, "signed on as the provider"

    get "/lakeraven-ehr/dashboard"
    assert_response :ok
    assert_select "#needing-action-count", count: 0

    get LIST
    assert_response :forbidden
  end

  private

  def fm(time) = RpmsRpc::FilemanDateParser.to_fileman(time.change(sec: 0)).sub(/0+\z/, "").chomp(".")

  def ciav(&) = RpmsRpc.client.with_context("CIAV VUECENTRIC", &)

  # [{ id:, start:, patient:, resource: }] for the list's rows.
  def listed
    css_select("#needing-action tr[data-appointment]").map do |tr|
      { id: tr["data-appointment"], start: tr.at_css("td[data-start]")["data-start"], patient: tr["data-patient"], resource: tr["data-resource"] }
    end
  end

  def dashboard_count
    get "/lakeraven-ehr/dashboard"
    assert_response :ok
    cell = css_select("#needing-action-count").first
    assert cell, "the dashboard counts appointments needing action for a scheduler"
    assert_equal LIST, cell.at_css("a")["href"]
    cell["data-count"].to_i.tap { |n| assert_equal n.to_s, cell.at_css("a").text.split.first }
  end

  # Books MOUSE at the clinic on day through BSDX ADD NEW APPOINTMENT, at a
  # quarter hour the patient is free, between 08:00 and 16:00 unless between
  # names other times; { id:, start: }.
  def book(day, between: Time.new(day.year, day.month, day.day, 8)..Time.new(day.year, day.month, day.day, 16))
    quarters = (between.begin.to_i..between.end.to_i).step(900).map { |t| Time.at(t - (t % 900)) }.select { |t| between.cover?(t) }
    quarters.sample(30).each do |start|
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: CLINIC, start_time: start, end_time: start + 900, length_minutes: 15)
      return { id: reply[:appointment_id], start: start } if reply && reply[:success]
    end
    flunk "no time on #{day} took a booking"
  end

  def check_in(appointment, day)
    path = "#{@clinic}/appointments/#{appointment[:id]}/checkin"
    get path, params: { date: day.iso8601, provider_search: "PROFILE" }
    provider = css_select("#checkin-form label[data-provider]").find { |l| l.text.upcase.include?("PROFILE,MD") }["data-provider"]
    post path, params: { date: day.iso8601, checkin: { at: (appointment[:start] + 300).strftime("%Y-%m-%dT%H:%M"), provider_ien: provider } }
    assert_response :redirect, "checked in: #{response.status} #{css_select("[role='alert']").map(&:text).join(' ').squish}"
    appointment[:state] = "checked in"
  end

  def check_out(appointment, day)
    post "#{@clinic}/appointments/#{appointment[:id]}/checkout", params: { date: day.iso8601, checkout: { at: (appointment[:start] + 1200).strftime("%Y-%m-%dT%H:%M") } }
    assert_response :redirect, "checked out"
    appointment[:state] = "checked out"
  end

  def cancel(appointment, day)
    path = "#{@clinic}/appointments/#{appointment[:id]}/cancel"
    get path, params: { date: day.iso8601, whom: "C" }
    reason = css_select("#cancellation-form select option").find { |o| o["value"].present? }["value"]
    post path, params: { date: day.iso8601, cancellation: { whom: "C", reason_ien: reason, remarks: "live needing action" } }
    assert_response :redirect, "cancelled"
    appointment[:state] = "cancelled"
  end

  # [["YYYY-MM-DDTHH:MM", dfn]] for every patient booked at the clinic on day
  # whose #2.98 CURRENT STATUS (field 100) is empty or NO ACTION TAKEN: the
  # appointments BSDAMR2 lists, read the way it walks them (^SC(clinic,"S")).
  def no_action_on_clinic(day)
    hloc = @resource[:hospital_location_id]
    times = ciav { RpmsRpc::DdrFileman.lister(file: "44.001", iens: ",#{hloc},", fields: "@;.01I", flags: "IP", max: "*") }
    flunk "DDR LISTER on #44.001 at #{hloc}: #{times.inspect}" unless times && !times[:error]
    times[:entries].map { |e| e[:pieces][0] }.select { |t| t.start_with?(fm(day.to_time)[0, 7]) }.flat_map do |time|
      patients = ciav { RpmsRpc::DdrFileman.lister(file: "44.003", iens: ",#{time},#{hloc},", fields: "@;.01I", flags: "IP", max: "*") }
      patients[:entries].filter_map do |e|
        dfn = e[:pieces][0]
        got = ciav { RpmsRpc::DdrFileman.gets_entry(file: "2.98", iens: "#{time},#{dfn},", fields: "100", flags: "E") }.dig(:fields, "100") || {}
        status = (got[:external].presence || got[:internal]).to_s
        [ RpmsRpc::FilemanDateParser.parse_datetime(time).strftime("%Y-%m-%dT%H:%M"), dfn ] if status.empty? || status.include?("NO ACTION TAKEN")
      end
    end
  end
end
