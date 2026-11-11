# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/referral"

# Demo prototype: what any registered outside app integration needs (an
# outreach app, a scribe, ...), end to end on synthetic data. Not in the
# December build, and the FHIR API is not certified. bin/demo_app_integration
# runs this and prints each step (DEMO_TRANSCRIPT=1).
#
#   0. The app is registered with SMART Backend Services and gets a scoped
#      token (system/Patient.r, ServiceRequest.rs, Communication.cr). A token
#      without Communication create is refused the write.
#   1. It reads the synthetic patient and their referral over FHIR
#      (Patient, ServiceRequest).
#   2. A stand-in client (this file: a script, no AI) posts the call outcome
#      as a FHIR Communication.
#   3. It is held as pending for review, never applied, and audited.
#   4. A coordinator confirms it on the review page.
#   5. Confirming writes it to the RPMS referral (BMC UPDATE REFERRAL, through
#      rpms-rpc's Referral.record_follow_up) and reads it back from RPMS.
#
# Two modes:
# - Test harness (default): the mock broker, seeded by RcisFollowUpMock with
#   what RPMS would answer. Every RPMS reply is seeded, not live.
# - Live (LIVE_RPMS=1 LIVE_RPMS_WRITES=1, see test_helper.rb): a throwaway
#   container of the pinned RPMS image. It WRITES to a synthetic referral.
#   The whole process is signed on to RPMS as LIVE_RPMS_ACCESS, the way every
#   live test here runs, so the FHIR reads in step 1 use that identity. A
#   deployed stack would answer them 503 until #844 gives a backend token an
#   RPMS identity of its own.
class AppIntegrationDemoTest < ActionDispatch::IntegrationTest
  include RcisFollowUpMock

  LIVE = defined?(LIVE_RPMS) && LIVE_RPMS
  DFN = Integer(ENV.fetch("DEMO_PATIENT_DFN", LIVE ? "990003" : "3"))
  MOCK_REFERRAL_IEN = 7001
  CLIENT_ID = "registered-outside-app-demo"
  APP_NAME = "Registered outside app (stand-in)"
  JWKS_URI = "https://outside-app.example.test/.well-known/jwks.json"
  TOKEN_URL = "/lakeraven-ehr/oauth/token"
  SCOPES = "system/Patient.r system/ServiceRequest.rs system/Communication.cr"
  READ_ONLY_SCOPES = "system/Patient.r system/ServiceRequest.rs"
  OUTCOME = "Patient says the cardiology appointment is booked for 12/4."
  APPOINTMENT = Date.new(2026, 12, 4)
  REFERRAL_FILE = "90001"

  setup do
    if LIVE && ENV["LIVE_RPMS_WRITES"] != "1"
      skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container"
    end
    Lakeraven::EHR::LoginThrottle.reset!
    @key = OpenSSL::PKey::RSA.new(2048)
    @jwk = JWT::JWK.new(@key)
    published = { JWKS_URI => { keys: [ @jwk.export ] } }
    # The stand-in app publishes no real JWKS, so its key set is served in-process.
    Lakeraven::EHR::ClientJwks.singleton_class.send(:alias_method, :fetch_before_demo, :fetch)
    Lakeraven::EHR::ClientJwks.define_singleton_method(:fetch) { |uri| published[uri] }
  end

  teardown do
    if Lakeraven::EHR::ClientJwks.singleton_class.method_defined?(:fetch_before_demo)
      Lakeraven::EHR::ClientJwks.singleton_class.send(:remove_method, :fetch)
      Lakeraven::EHR::ClientJwks.singleton_class.send(:alias_method, :fetch, :fetch_before_demo)
      Lakeraven::EHR::ClientJwks.singleton_class.send(:remove_method, :fetch_before_demo)
    end
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
    Lakeraven::EHR::BackendAssertionJti.delete_all
    LiveRpmsSession.sign_on! if LIVE
  end

  test "a registered outside app reads a referral, posts the call outcome, and a confirmed result reaches the RPMS referral" do
    say "Mode: #{LIVE ? 'LIVE RPMS broker' : 'TEST HARNESS (mock broker; every RPMS reply is seeded, not live)'}"
    say "Demo prototype on synthetic data. Not in the December build. The FHIR API is not certified."

    # 0. Registration and a scoped token -------------------------------------
    step 0, "Register the outside app (SMART Backend Services) and get a scoped token"
    Doorkeeper::Application.create!(name: APP_NAME, uid: CLIENT_ID, redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
                                    confidential: true, scopes: SCOPES, jwks_uri: JWKS_URI,
                                    organization_id: "demo-organization")
    token = backend_token(SCOPES)
    say "  token granted with scope: #{@granted_scope}"
    read_only = backend_token(READ_ONLY_SCOPES)
    say "  a second token granted with scope: #{@granted_scope}"

    ien = demo_referral_ien
    post_communication(communication(ien), read_only)
    assert_response :forbidden
    say "  POST /Communication with the read-only token -> HTTP #{response.status} (refused: no Communication create scope)"

    # 1. Read the patient and the referral over FHIR -------------------------
    step 1, "Read the synthetic patient and their referral over FHIR"
    get "/lakeraven-ehr/Patient/#{DFN}", headers: auth(token)
    assert_response :ok
    patient = JSON.parse(response.body)
    say "  GET /Patient/#{DFN} -> HTTP 200, #{patient.dig('name', 0, 'family')}, #{patient.dig('name', 0, 'given')&.join(' ')}"
    get "/lakeraven-ehr/ServiceRequest", params: { patient: DFN }, headers: auth(token)
    assert_response :ok
    referral = Array(JSON.parse(response.body)["entry"]).map { |e| e["resource"] }.find { |r| r["id"] == "#{DFN}-#{ien}" }
    assert referral, "ServiceRequest/#{ien} is in Patient/#{DFN}'s referrals"
    say "  GET /ServiceRequest?patient=#{DFN} -> HTTP 200, ServiceRequest/#{referral['id']} (RPMS referral #{ien}) status #{referral['status']}"

    # 2. The stand-in client posts the call outcome ---------------------------
    step 2, "The stand-in client posts the call outcome as a FHIR Communication"
    say "  payload: #{OUTCOME.inspect}, appointmentDate #{APPOINTMENT.iso8601}, reached true, tagged AI-asserted as an AI app's result would be"
    post_communication(communication(ien), token)
    assert_response :created
    posted = JSON.parse(response.body)
    say "  POST /Communication -> HTTP 201, Communication/#{posted['id']} status #{posted['status']}"
    assert_equal "in-progress", posted["status"]

    # 3. Held for review, not applied, audited --------------------------------
    step 3, "Held as pending for review, never applied automatically, and audited"
    follow_up = Lakeraven::EHR::AppFollowUp.find(posted["id"])
    assert follow_up.pending?
    say "  follow-up #{follow_up.id}: status #{follow_up.status}; RPMS referral writes so far: #{bmc_update_count}"
    assert_equal 0, bmc_update_count
    audit = Lakeraven::EHR::AuditEvent.where(event_type: "application", action: "C").last
    say "  AuditEvent #{audit.id}: action C, agent Device/#{audit.agent_who_identifier}, entity Patient/#{audit.entity_identifier}, #{audit.outcome_desc}"

    # 4. A coordinator confirms it on the review page -------------------------
    step 4, "A coordinator confirms it on the review page"
    sign_in_coordinator
    get "/lakeraven-ehr/referrals/follow_ups"
    assert_response :ok
    assert_select "#pending-follow-ups tr[data-follow-up='#{follow_up.id}']"
    say "  GET /referrals/follow_ups -> HTTP 200, follow-up #{follow_up.id} listed as pending, labeled AI-generated"
    seed_harness_write(ien, follow_up) unless LIVE
    post "/lakeraven-ehr/referrals/follow_ups/#{follow_up.id}/confirm"
    follow_redirect!
    assert_response :ok
    follow_up.reload
    say "  POST confirm -> confirmed by #{follow_up.reviewed_by_name} at #{follow_up.reviewed_at.iso8601}"

    # 5. Written to the RPMS referral and read back ---------------------------
    step 5, "Write it back to the RPMS referral over RPC, then read it back from RPMS"
    assert follow_up.written_back?, "write-back failed: #{follow_up.write_back_detail}"
    unless LIVE
      assert_equal 1, bmc_update_count
      assert_equal follow_up.case_note, bmc_update_calls.last[29], "the case note sent is the one confirmed"
      say "  BMC UPDATE REFERRAL sent once (30 parameters); #{follow_up.write_back_detail}"
    end
    say "  #{follow_up.write_back_detail}" if LIVE
    state = RpmsRpc::Referral.follow_up_state(ien)
    note = state[:case_notes].last
    say "  #{LIVE ? 'RPMS' : '[seeded mock reply] RPMS'} referral #{ien} now reads: status #{state[:status]}, date of service (1106) #{state[:appointment]}"
    say "  #{LIVE ? '' : '[seeded mock reply] '}newest case note #{note[:ien]}: #{note[:text]}"
    assert_match(/\A3261204/, state[:appointment])
    assert_equal follow_up.case_note, note[:text].strip
    get "/lakeraven-ehr/Communication/#{follow_up.id}", headers: auth(token)
    say "  the app reads back GET /Communication/#{follow_up.id} -> status #{JSON.parse(response.body)['status']}"
    assert_equal "completed", JSON.parse(response.body)["status"]
    say "DEMO COMPLETE: #{LIVE ? 'live RPMS' : 'test harness'}"
  end

  private

  def say(line)
    puts line if ENV["DEMO_TRANSCRIPT"] == "1"
  end

  def step(number, title)
    say "\n== Step #{number}: #{title}"
  end

  def auth(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def backend_token(scope)
    claims = { iss: CLIENT_ID, sub: CLIENT_ID, aud: "http://www.example.com#{TOKEN_URL}",
               exp: 5.minutes.from_now.to_i, jti: SecureRandom.uuid }
    post TOKEN_URL, params: { grant_type: "client_credentials", scope: scope,
                              client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                              client_assertion: JWT.encode(claims, @key, "RS384", kid: @jwk[:kid]) }
    assert_response :ok
    body = JSON.parse(response.body)
    @granted_scope = body["scope"]
    body.fetch("access_token")
  end

  def communication(ien)
    {
      resourceType: "Communication", status: "completed",
      meta: { tag: [ { system: "http://terminology.hl7.org/CodeSystem/v3-ObservationValue", code: "AIAST" } ] },
      subject: { reference: "Patient/#{DFN}" }, about: [ { reference: "ServiceRequest/#{DFN}-#{ien}" } ],
      sender: { reference: "Device/#{CLIENT_ID}" }, payload: [ { contentString: OUTCOME } ],
      extension: [ { url: Lakeraven::EHR::AppFollowUp::EXTENSION, extension: [
        { url: "reached", valueBoolean: true }, { url: "appointmentDate", valueDate: APPOINTMENT.iso8601 }
      ] } ]
    }
  end

  def post_communication(body, token)
    post "/lakeraven-ehr/Communication", params: body.to_json,
                                         headers: auth(token).merge("Content-Type" => "application/fhir+json")
  end

  def bmc_update_count
    LIVE ? 0 : bmc_update_calls.size
  end

  def sign_in_coordinator
    if LIVE
      post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
      assert_response :redirect, "signed on as the referral coordinator"
    else
      post "/lakeraven-ehr/test_session", params: { duz: "206", user_type: "provider", user_name: "PROFILE,MD",
                                                    security_keys: "referrals_user" }
    end
  end

  # The synthetic referral the demo works on. Harness: seeded. Live: an ACTIVE
  # referral of the synthetic patient with no EHR link, or one filed with DDR
  # FILER (BMC ADD REFERRAL cannot be called on YottaDB, rpms-rpc#722).
  def demo_referral_ien
    return seed_open_referral(dfn: DFN, ien: MOCK_REFERRAL_IEN) && MOCK_REFERRAL_IEN unless LIVE

    listed = RpmsRpc::DdrFileman.lister(file: REFERRAL_FILE, fields: "@;.03;.15;1303", flags: "IP", max: "*")
    flunk "DDR LISTER on file #{REFERRAL_FILE} answered #{listed.inspect}" if listed.nil? || listed[:error]
    found = listed[:entries].find { |e| e[:pieces][0] == DFN.to_s && e[:pieces][1] == "A" && e[:pieces][2].to_s.empty? }
    return found[:ien].to_i if found

    today = Date.today
    values = { ".01" => format("%<y>03d%<m>02d%<d>02d", y: today.year - 1700, m: today.month, d: today.day),
               ".03" => DFN.to_s, ".04" => "N", ".14" => "O", ".15" => "A" }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: values.map { |f, v| { file: REFERRAL_FILE, field: f, iens: "+1,", value: v } })
    assert filed && filed[:success], "DDR FILER could not file a synthetic referral: #{filed.inspect}"
    say "  (filed synthetic referral #{filed[:iens].fetch(1)} for Patient/#{DFN} with DDR FILER)"
    filed[:iens].fetch(1).to_i
  end

  # Harness only: the routine's reply and what RPMS would read back, seeded
  # with the note the write-back is about to send (checked against the call).
  def seed_harness_write(ien, follow_up)
    reviewer = "PROFILE,MD"
    note = follow_up.dup.tap { |f| f.reviewed_by_name = reviewer }.case_note
    seed_update_reply(ien: ien)
    seed_read_back(ien: ien, appointment: "3261204.12", note_text: note)
  end
end
