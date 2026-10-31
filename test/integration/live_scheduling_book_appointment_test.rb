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
    day = Date.today + 7 + rand(7)
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

  test "S-SCH-02.1 and 02.6 the scheduler cancels an appointment for the clinic, which frees its place, once" do
    get "/lakeraven-ehr/scheduling"
    clinic = css_select("#resources a").find { |a| a.text == "DEMO IHS CLINIC" }["href"]
    day = weekday_ahead
    get clinic, params: { date: day.iso8601 }
    time = css_select("#open-times tr").select { |tr| tr["data-time"].to_s >= "11:00" && tr.at_css("td[data-open]")["data-open"].to_i.positive? }.sample["data-time"]
    open_before = css_select("#open-times tr[data-time='#{time}'] td[data-open]").first["data-open"].to_i
    post "#{clinic}/appointments", params: { booking: { patient_dfn: "3", start: "#{day.iso8601}T#{time}", length: "15", note: "" } }
    follow_redirect!
    row = css_select("#appointments tr[data-patient='3']").find { |tr| tr.at_css("td").text.start_with?(time) }
    cancel = row.at_css("a")["href"]

    get cancel.split("?").first, params: { date: day.iso8601, whom: "C" }
    reason = css_select("#cancellation-form select option").find { |o| o.text == "CLINIC STAFFING" }["value"]
    post cancel.split("?").first, params: { date: day.iso8601, cancellation: { whom: "C", reason_ien: reason, remarks: "live cancel" } }
    assert_response :redirect
    follow_redirect!
    assert_select "#appointments tr[data-appointment='#{row['data-appointment']}'] td[data-status='cancelled']"
    assert_select "#open-times tr[data-time='#{time}'] td[data-open='#{open_before}']"

    post cancel.split("?").first, params: { date: day.iso8601, cancellation: { whom: "C", reason_ien: reason, remarks: "again" } }
    assert_response :conflict
  end

  test "S-SCH-03.1, 03.7 and 02.5 the scheduler checks a patient in today, once, and it can no longer be cancelled" do
    get "/lakeraven-ehr/scheduling"
    clinic = css_select("#resources a").find { |a| a.text == "DEMO IHS CLINIC" }["href"]
    today = Date.today
    get clinic, params: { date: today.iso8601 }
    open = css_select("#open-times tr[data-time]").select { |tr| tr.at_css("td[data-open]")["data-open"].to_i.positive? }
    skip "no open time left today on the throwaway container" if open.empty?
    time = open.sample["data-time"]
    post "#{clinic}/appointments", params: { booking: { patient_dfn: "3", start: "#{today.iso8601}T#{time}", length: "15", note: "" } }
    skip "MOUSE already has an appointment at #{time} today" if response.status == 422
    follow_redirect!
    row = css_select("#appointments tr[data-patient='3']").find { |tr| tr.at_css("td").text.start_with?(time) && tr.at_css("td[data-status='booked']") }
    checkin = row.css("a").find { |a| a.text == "Check in" }["href"].split("?").first

    get checkin, params: { date: today.iso8601, provider_search: "PROFILE" }
    provider = css_select("#checkin-form label[data-provider]").find { |l| l.text.upcase.include?("PROFILE,MD") }["data-provider"]
    now = Time.now.strftime("%Y-%m-%dT%H:%M")
    post checkin, params: { date: today.iso8601, checkin: { at: now, provider_ien: provider } }
    assert_response :redirect
    follow_redirect!
    assert_select "#appointments tr[data-appointment='#{row['data-appointment']}'] td[data-status='checked']"

    post checkin, params: { date: today.iso8601, checkin: { at: now, provider_ien: provider } }
    assert_response :conflict
    post checkin.sub("/checkin", "/cancel"), params: { date: today.iso8601, cancellation: { whom: "C", reason_ien: "7", remarks: "" } }
    assert_response :conflict
  end

  test "S-SCH-04.1, 04.5 and 04.7 the scheduler finds an afternoon open time next week and books it, at the length searched for" do
    get "/lakeraven-ehr/scheduling"
    clinic = css_select("#resources a").find { |a| a.text == "DEMO IHS CLINIC" }["href"]
    day = weekday_ahead
    get "#{clinic}/open_times", params: { from: day.iso8601, to: (day + 6).iso8601, length: "30", part: "pm" }
    assert_response :ok

    times = css_select("#open-times [data-date='#{day.iso8601}'] a[data-time]")
    refute_empty times, "the clinic's afternoon on #{day} has open times"
    assert(times.all? { |a| a["data-time"] >= "12:00" })
    pick = times.to_a.sample
    get pick["href"]
    assert_response :ok

    start = "#{day.iso8601}T#{pick['data-time']}"
    post "#{clinic}/appointments", params: { booking: { patient_dfn: "3", start: start, length: "30", note: "" } }
    skip "MOUSE already has an appointment at #{pick['data-time']} on #{day}" if response.status == 422
    assert_response :redirect
    follow_redirect!
    row = css_select("#appointments tr[data-patient='3']").find { |tr| tr.at_css("td").text.start_with?(pick["data-time"]) && tr.at_css("td[data-status='booked']") }
    assert row, "the booking shows on the clinic's day"
    finish = (Time.strptime(pick["data-time"], "%H:%M") + 1800).strftime("%H:%M")
    assert_match(/#{pick['data-time']}.#{finish}/, row.at_css("td").text, "booked for the 30 minutes searched for")
  end

  test "S-SCH-05.6 and 05.7 the scheduler opens MOUSE,MICKEY M's future appointments and finds the one just booked" do
    get "/lakeraven-ehr/scheduling"
    clinic = css_select("#resources a").find { |a| a.text == "DEMO IHS CLINIC" }["href"]
    day = weekday_ahead
    get "#{clinic}/open_times", params: { from: day.iso8601, to: day.iso8601, length: "15", part: "pm" }
    pick = css_select("#open-times [data-date='#{day.iso8601}'] a[data-time]").to_a.sample
    skip "no afternoon time left on #{day}" unless pick
    post "#{clinic}/appointments", params: { booking: { patient_dfn: "3", start: "#{day.iso8601}T#{pick['data-time']}", length: "15", note: "" } }
    skip "MOUSE already has an appointment at #{pick['data-time']} on #{day}" if response.status == 422
    assert_response :redirect

    get "/lakeraven-ehr/scheduling/patients/3/appointments", params: { when: "future" }
    assert_response :ok
    start = Time.new(day.year, day.month, day.day, *pick["data-time"].split(":").map(&:to_i)).iso8601
    row = css_select("#patient-appointments tr[data-start='#{start}']").first
    assert row, "the appointment booked at #{start} is listed"
    assert_equal "scheduled", row["data-status"]
    assert_match(/DEMO IHS CLINIC/, row.text)
    assert(css_select("#patient-appointments tr[data-start]").all? { |tr| Time.iso8601(tr["data-start"]).to_date > Date.today })

    get row.at_css("a[data-clinic-day]")["href"]
    assert_select "#appointments tr[data-patient='3'] td", text: /\A#{pick['data-time']}/
  end

  test "S-SCH-01.12 the front desk, who holds no scheduling key, cannot open scheduling" do
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PREG123", password: "PREG123!!" }
    get "/lakeraven-ehr/scheduling"

    assert_response :forbidden
  end

  test "S-SCH-04.3 and 04.4 the search leaves out a holiday, the days past the clinic's booking limit, and its inactive days" do
    get "/lakeraven-ehr/scheduling"
    clinic = css_select("#resources a").find { |a| a.text == "DEMO IHS CLINIC" }["href"]
    ien = RpmsRpc::Scheduling.resources.find { |r| r[:name] == "DEMO IHS CLINIC" }[:hospital_location_id]
    holiday = RpmsRpc::SchedulingSetup.holidays(start_date: Date.today + 1, end_date: Date.today + 90)
                                     .map { |h| h[:date] }.find { |d| d.monday? || d.tuesday? || d.wednesday? }
    flunk "no HOLIDAY (#40.5) on a Monday to Wednesday in the next 90 days" unless holiday
    original = RpmsRpc::SchedulingSetup.clinic_rules(ien)
    week = holiday - 1..holiday + 2
    days_ahead = (holiday + 1 - Date.today).to_i

    begin
      file_clinic(ien, "1918.5" => "@", "2002" => days_ahead.to_s)
      get "#{clinic}/open_times", params: { from: week.first.iso8601, to: week.last.iso8601, length: "15" }
      assert_equal %w[- holiday - beyond_booking], week.map { |d| day_closed(d) || "-" }
      refute_empty day_times(holiday - 1)
      assert_empty day_times(holiday)
      refute_empty day_times(holiday + 1), "the last day inside the booking limit"
      assert_empty day_times(holiday + 2)

      file_clinic(ien, "1918.5" => "Y", "2002" => "365", "2505" => fm(holiday + 1), "2506" => fm(holiday + 2))
      get "#{clinic}/open_times", params: { from: week.first.iso8601, to: week.last.iso8601, length: "15" }
      assert_equal %w[- - inactive -], week.map { |d| day_closed(d) || "-" }
      refute_empty day_times(holiday), "the clinic schedules on holidays now"
      refute_empty day_times(holiday + 2), "reactivated"
    ensure
      file_clinic(ien, "1918.5" => original[:schedule_on_holidays] ? "Y" : "@", "2002" => original[:max_future_days]&.to_s || "@",
                       "2505" => original[:inactivate_date] ? fm(original[:inactivate_date]) : "@",
                       "2506" => original[:reactivate_date] ? fm(original[:reactivate_date]) : "@")
    end
    assert_equal original, RpmsRpc::SchedulingSetup.clinic_rules(ien), "the clinic's fields are put back"
  end

  test "S-SCH-04.2 and 04.6 the search keeps to one access type, and never offers a block whose type prevents access" do
    get "/lakeraven-ehr/scheduling"
    clinic = css_select("#resources a").find { |a| a.text == "DEMO IHS CLINIC" }["href"]
    walk_in = access_type("LIVE WALK IN", prevents: false)
    held = access_type("LIVE SPEC PREVENTS", prevents: true)
    day = Date.today + 21 + rand(21)
    day += 1 while day.saturday? || day.sunday? || day.friday?
    blocks = [ add_block(day, walk_in), add_block(day + 1, held) ]

    begin
      get "#{clinic}/open_times", params: { from: day.iso8601, to: (day + 1).iso8601, length: "15" }
      assert_includes day_times(day), "17:00"
      refute(day_times(day + 1).any? { |t| t >= "17:00" }, "no time in the block whose type prevents access")
      options = css_select("#access_type option").map(&:text)
      assert_includes options, "LIVE WALK IN"
      refute_includes options, "LIVE SPEC PREVENTS"

      get "#{clinic}/open_times", params: { from: day.iso8601, to: day.iso8601, length: "15", access_type: walk_in }
      assert_equal %w[17:00 17:15 17:30 17:45], day_times(day)

      post "#{clinic}/appointments", params: { booking: { patient_dfn: "3", start: "#{(day + 1).iso8601}T17:15", length: "15", note: "" } }
      assert_response :conflict
    ensure
      blocks.each { |id| bsdx("BSDX CANCEL AVAILABILITY", id.to_s) }
    end
  end

  private

  def day_times(date) = css_select("#open-times [data-date='#{date.iso8601}'] a[data-time]").map { |a| a["data-time"] }

  def day_closed(date) = css_select("#open-times [data-date='#{date.iso8601}']").first["data-closed"].presence

  def fm(date) = RpmsRpc::FilemanDateParser.to_fileman(date)

  # #44 fields through DDR FILER, as the signed-on scheduler (CIAV VUECENTRIC).
  def file_clinic(ien, values)
    rows = values.map { |field, value| { file: 44, field: field, iens: "#{ien},", value: value } }
    got = RpmsRpc.client.with_context("CIAV VUECENTRIC") { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows) }
    assert got && got[:success], "DDR FILER on #44 #{ien}: #{got.inspect}"
  end

  # A BSDX RPC in BSDXRPC, its reply as one string.
  def bsdx(rpc, *params)
    client = RpmsRpc.client
    Array(client.with_context("BSDXRPC") { client.call_rpc_global_array(rpc, *params) }).join
  end

  # The access type of that name, filed through the scheduling client's own
  # BSDX ADD/EDIT ACCESS TYPE (IEN|NAME|INACTIVE|COLOR|RED|GREEN|BLUE|PREVENT).
  def access_type(name, prevents:)
    id = RpmsRpc::SchedulingSetup.access_types.find { |t| t[:name] == name }&.dig(:id) || 0
    reply = bsdx("BSDX ADD/EDIT ACCESS TYPE", "#{id}|#{name}|NO|||||#{prevents ? 'YES' : 'NO'}")
    refute_match(/BSDX14:/, reply)
    RpmsRpc::SchedulingSetup.access_types.find { |t| t[:name] == name }.fetch(:id)
  end

  # A 17:00-18:00 block of two slots of the type on DEMO IHS CLINIC.
  def add_block(date, type)
    on = date.strftime("%m-%d-%Y")
    reply = bsdx("BSDX ADD NEW AVAILABILITY", "#{on}@1700", "#{on}@1800", type.to_s, "DEMO IHS CLINIC", "2", "")
    id = reply[/(\d+)\^-1/, 1]
    assert id && id.to_i.positive?, "BSDX ADD NEW AVAILABILITY: #{reply.inspect}"
    id.to_i
  end
end
