# frozen_string_literal: true

# For live tests that chart on a visit (LIVE_RPMS=1 LIVE_RPMS_WRITES=1, a
# throwaway container only): the scheduler books the patient today and checks
# them in through the app, which files the visit; then a persona signs on and
# opens the chart. The same steps as test/integration/live_progress_note_sign_test.rb
# on the #1001 branch.
module LiveVisitHelper
  CLINIC = "DEMO IHS CLINIC"

  def live_writes? = defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"

  def ciav(&) = RpmsRpc.client.with_context("CIAV VUECENTRIC", &)

  def csrf = css_select("meta[name='csrf-token']").first&.[]("content")

  def sign_in(access, verify)
    Lakeraven::EHR::LoginThrottle.reset!
    get "/lakeraven-ehr/login"
    post "/lakeraven-ehr/login", params: { username: access, password: verify, authenticity_token: csrf }
    assert_response :redirect, "sign-on as #{access}"
    follow_redirect! while response.redirect?
  end

  def open_chart(dfn)
    post "/lakeraven-ehr/patients/#{dfn}/context", params: { authenticity_token: csrf }
    get "/lakeraven-ehr/patients/#{dfn}"
    assert_response :ok
  end

  # Books the patient into an open time today and checks the appointment in
  # as the scheduler, through the app. Answers the VISIT IEN the check-in filed.
  def check_in_as_scheduler(dfn)
    sign_in("PSCH123", "PSCH123!!")
    resource = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }
    hloc = resource[:hospital_location_id]
    before = newest_visit(dfn, hloc)
    path = "/lakeraven-ehr/scheduling/clinics/#{resource[:id]}/appointments/#{book_today(dfn)}"
    get "#{path}/checkin", params: { date: Date.today.iso8601, provider_search: "PROFILE" }
    provider = css_select("#checkin-form label[data-provider]").find { |l| l.text.upcase.include?("PROFILE,MD") }["data-provider"]
    post "#{path}/checkin", params: { date: Date.today.iso8601, authenticity_token: csrf,
                                      checkin: { at: (Time.now - 600).strftime("%Y-%m-%dT%H:%M"), provider_ien: provider } }
    assert_response :redirect, "checked in: #{response.status} #{css_select("[role='alert']").map(&:text).join(' ').squish}"
    visit = newest_visit(dfn, hloc)
    assert visit && visit != before, "the check-in filed a new visit at #{CLINIC}"
    visit
  end

  # Booked as setup through BSDX, earlier today. Answers the appointment id.
  def book_today(dfn)
    today = Date.today
    20.times do
      start = Time.new(today.year, today.month, today.day, 7 + rand(3), [ 0, 15, 30, 45 ].sample)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: dfn, resource: CLINIC, start_time: start,
                                                  end_time: start + 900, length_minutes: 15)
      return reply[:appointment_id] if reply && reply[:success]
    end
    flunk "no time today took a booking"
  end

  # The IEN of the patient's newest VISIT at the hospital location, from the
  # newest 50 visits on file.
  def newest_visit(dfn, hloc)
    page = ciav { RpmsRpc::DdrFileman.lister(file: "9000010", fields: "@;.05I;.22I", flags: "IPB", max: "50", xref: "#") }
    page[:entries].select { |e| e[:pieces] == [ dfn.to_s, hloc.to_s ] }.map { |e| e[:ien].to_s }.max_by(&:to_i)
  end
end
