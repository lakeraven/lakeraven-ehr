# frozen_string_literal: true

require "test_helper"

# Live (lakeraven-ehr#1001 "Done when"): on a real RPMS, the scheduler checks
# a patient in, which files a visit; the clinician persona (PROVIDER, with an
# electronic signature code) opens the chart, writes a progress note on that
# visit and signs it; TIU DOCUMENT #8925 is read back with FileMan. It WRITES,
# so it runs only against a throwaway container and only when asked twice:
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' PROGRESS_NOTE_TITLE_IEN=248 \
#   bin/rails test test/integration/live_progress_note_sign_test.rb
class LiveProgressNoteSignTest < ActionDispatch::IntegrationTest
  CLINIC = "DEMO IHS CLINIC"
  PATIENT = 3
  ESIG = "123456"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR.reset_configuration!
    @title = Lakeraven::EHR.configuration.progress_note_title_ien
    flunk "set PROGRESS_NOTE_TITLE_IEN to a progress note title on this build" unless @title
    # The browser path, CSRF included: the note form and the context POST check it.
    @forgery_was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"

    ActionController::Base.allow_forgery_protection = @forgery_was
    LiveRpmsSession.sign_on!
  end

  test "the clinician writes and signs a progress note on the visit check-in filed" do
    visit_ien = check_patient_in_as_scheduler
    log "visit filed by check-in: #{visit_ien}"

    sign_in("PMD123", "PMD123!!")
    follow_redirect! while response.redirect?
    post "/lakeraven-ehr/patients/#{PATIENT}/context", params: { authenticity_token: csrf }
    assert_redirected_to "/lakeraven-ehr/patients/#{PATIENT}"
    get "/lakeraven-ehr/patients/#{PATIENT}"
    assert_response :ok
    assert_select "a[href='/lakeraven-ehr/patients/#{PATIENT}/notes/new']", text: "Write note"

    get "/lakeraven-ehr/patients/#{PATIENT}/notes/new"
    assert_response :ok
    offered = css_select("input[name='visit_ien']").map { |i| i["value"] }
    log "open visits offered: #{offered.inspect}"
    assert_includes offered, visit_ien, "the visit check-in filed is offered as open"
    token = css_select("input[name='note_form_token']").first["value"]

    text = "Live note #{Time.now.utc.iso8601} for lakeraven-ehr#1001."
    post "/lakeraven-ehr/patients/#{PATIENT}/notes",
         params: { visit_ien: visit_ien, note_text: text, signature_code: ESIG, note_form_token: token, authenticity_token: csrf }
    assert_response :redirect, "filed: #{response.status} #{css_select("[role='alert']").map(&:text).join(' ').squish}"
    follow_redirect!
    assert_match(/Progress note signed/, response.body)

    LiveRpmsSession.sign_on!
    note = newest_note
    flunk "no #8925 entry for DFN #{PATIENT}" unless note
    got = ciav { RpmsRpc::DdrFileman.gets_entry(file: "8925", iens: "#{note},", fields: ".01;.02;.03;.05;1202;1501;1502", flags: "IE") }
    log "#8925 #{note}: #{got[:fields].inspect}"
    fields = got[:fields]
    assert_equal PATIENT.to_s, fields.dig(".02", :internal).to_s
    assert_equal visit_ien, fields.dig(".03", :internal).to_s, "VISIT is the check-in's visit, not -1"
    assert_equal "COMPLETED", fields.dig(".05", :external).to_s
    assert_equal "206", fields.dig("1502", :internal).to_s, "SIGNED BY is PROFILE,MD"
    assert_equal "206", fields.dig("1202", :internal).to_s, "AUTHOR is PROFILE,MD"
    body = ciav { RpmsRpc::ProgressNote.fetch_text(note.to_s) }
    log "note text: #{body.inspect[0, 300]}"
  end

  private

  def log(line) = warn("[live #1001] #{line}")

  def ciav(&) = RpmsRpc.client.with_context("CIAV VUECENTRIC", &)

  def csrf = css_select("meta[name='csrf-token']").first&.[]("content")

  def sign_in(access, verify)
    Lakeraven::EHR::LoginThrottle.reset!
    get "/lakeraven-ehr/login"
    post "/lakeraven-ehr/login", params: { username: access, password: verify, authenticity_token: csrf }
    assert_response :redirect, "sign-on as #{access}"
  end

  def fm(time) = RpmsRpc::FilemanDateParser.to_fileman(time.change(sec: 0)).sub(/0+\z/, "").chomp(".")

  # Books MOUSE into an open time today and checks the appointment in as the
  # scheduler, through the app. Answers the VISIT IEN the check-in filed.
  def check_patient_in_as_scheduler
    sign_in("PSCH123", "PSCH123!!")
    resource = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }
    clinic = "/lakeraven-ehr/scheduling/clinics/#{resource[:id]}"
    hloc = resource[:hospital_location_id]
    before = newest_visit(hloc)&.first
    today = Date.today
    path = "#{clinic}/appointments/#{book_today}"
    get "#{path}/checkin", params: { date: today.iso8601, provider_search: "PROFILE" }
    provider = css_select("#checkin-form label[data-provider]").find { |l| l.text.upcase.include?("PROFILE,MD") }["data-provider"]
    post "#{path}/checkin", params: { date: today.iso8601, checkin: { at: (Time.now - 600).strftime("%Y-%m-%dT%H:%M"), provider_ien: provider }, authenticity_token: csrf }
    assert_response :redirect, "checked in: #{response.status} #{css_select("[role='alert']").map(&:text).join(' ').squish}"
    visit = newest_visit(hloc)
    assert visit && visit.first != before, "the check-in filed a new visit at #{CLINIC}"
    visit.first
  end

  # Booked as setup through BSDX, earlier today (a weekend day has no open
  # times for the app's booking form). Answers the appointment id.
  def book_today
    today = Date.today
    20.times do
      start = Time.new(today.year, today.month, today.day, 7 + rand(3), [ 0, 15, 30, 45 ].sample)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: CLINIC, start_time: start, end_time: start + 900, length_minutes: 15)
      return reply[:appointment_id] if reply && reply[:success]
    end
    flunk "no time today took a booking"
  end

  # [IEN, .01, .05, .22] of MOUSE's newest VISIT at the clinic.
  def newest_visit(hloc)
    rows = all_entries("9000010", "@;.01I;.05I;.22I")
    best = rows.select { |e| e[:pieces][1] == PATIENT.to_s && e[:pieces][2] == hloc.to_s }.max_by { |e| e[:ien].to_i }
    best && [ best[:ien].to_s, *best[:pieces] ]
  end

  # The newest TIU DOCUMENT for MOUSE.
  def newest_note
    all_entries("8925", "@;.02I").select { |e| e[:pieces][0] == PATIENT.to_s }.map { |e| e[:ien].to_i }.max
  end

  def all_entries(file, fields)
    rows = []
    from = nil
    loop do
      page = ciav { RpmsRpc::DdrFileman.lister(file: file, fields: fields, flags: "IP", max: "200", xref: "#", from: from) }
      rows.concat(page[:entries])
      break unless page[:more]

      from = page[:more][:value]
    end
    rows
  end
end
