# frozen_string_literal: true

require "test_helper"

# Closing the egress paths December does not need (#522): bulk EHI export,
# C-CDA transitions of care and the FHIR REST API (audit
# docs/compliance/part2-disclosure-surface-audit.md §1 paths 2–4, §5(a)).
#
# The host names the surfaces it wants OPEN in
# Rails.application.config.x.lakeraven_ehr.open_disclosure_surfaces. A closed
# surface answers 404 BEFORE authentication, BEFORE the rate limiter and
# BEFORE any broker call — a valid token with the right scopes gets the same
# 404 as no token — and the body carries no clinical content. The HTML chart
# (path 1) for a BROWSER SESSION, /metadata and the SMART discovery document
# are never governed by this switch.
#
# Amendment 1 (reviewer gaps A–C):
#   A. The HTML chart is the clinician's browser surface, reached with NO
#      Authorization header via the session token the sign-on bridge stashes.
#      A machine client sending `Authorization: Bearer …` would get the same
#      clinical content as text/html — API egress by another name. While
#      fhir_api is closed, a chart request carrying ANY Authorization header
#      is refused like a closed surface (404, before authentication, no
#      broker call, no clinical content), on the engine route and on the
#      host-root /patients/:dfn alike.
#   B. A host may draw routes straight at the engine's controllers (the dummy
#      app's /patients/:dfn and the test-only host_* routes in
#      test/dummy/config/routes.rb). Enforcement that lives only in the
#      engine's routing constraints does not reach them; closed must still
#      mean 404 there.
#   C. RateLimitable prepends its gate ahead of every before_action, so a
#      throttled client gets 429 (plus a rate-limit audit row) for a surface
#      that should not exist. A closed surface answers 404 even over the
#      limit, and writes no rate-limit audit row.
#
# Amendment 2 (reviewer gaps E–F):
#   E. Gap A closed the chart to a header token, but every OTHER browser
#      surface that authenticates a header bearer (SmartAuthentication, via
#      BrowserSmartAuthentication: screenings, patient contexts, allergies,
#      consents, the consent kiosk) was still open to a machine client while
#      every surface was closed. Reproduced: a Backend Services token with no
#      human sign-on fetched a CSRF token anonymously, POSTed a patient
#      context (302) and read a PHQ-9 result page — total, band, every item
#      answer and the item-9 self-harm note — as text/html. New rule: while
#      fhir_api is closed, a request carrying `Authorization: Bearer …` to ANY
#      engine controller that can authenticate a header token answers 404
#      before authentication, before CSRF/forgery handling has any side
#      effect, before any broker call, with no clinical content. The
#      enumerating sweep over every such controller lives in
#      test/integration/disclosure_surfaces_route_coverage_test.rb.
#   F. Only a header SmartAuthentication would authenticate FROM counts:
#      scheme `Bearer`, case-insensitive (extract_bearer_token's regexp). A
#      proxy-injected `Authorization: Basic …` is "no bearer found" and falls
#      through to the session, so it must not cost a signed-in browser its
#      chart or its screenings page. Amends gap A's "ANY header" rule.
#
# The dummy app's test environment opens all three so the rest of the suite
# keeps working; every test here sets the value itself and restores it.
class DisclosureSurfacesTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper

  PATIENT_DFN = "1"
  # Synthetic BASELINE_MOCK_SEEDS patient (test/test_helper.rb): "Anderson,Alice".
  PATIENT_NAME_PARTS = %w[Anderson Alice].freeze
  ALL_SURFACES = %i[fhir_api bulk_export ccda].freeze
  # Seeded test user (test/test_helper.rb): DUZ 304 RODRIGUEZ,LINDA, whose
  # RPMS keys grant the chart's Patient read scope through the sign-on bridge.
  BROWSER_USER = { username: "lindarodriguez", password: "test123" }.freeze
  # A behavioural-health clinician, seeded per test (the mock's seeds are
  # reset before every example): the AMHZMENU key mints the
  # QuestionnaireResponse scopes the screenings surface needs, and the chart
  # option mints the chart's Patient read, through the same sign-on bridge.
  BH_BROWSER_USER = { username: "bhtestuser", password: "test123" }.freeze
  BH_BROWSER_DUZ = "305"
  PHQ9 = Lakeraven::EHR::ScreeningInstrument::PHQ9
  CONTEXT_SESSION_KEY = Lakeraven::EHR::ClinicianPatientContext::SESSION_KEY
  # Words a PHQ-9 result page carries and a closed surface must not: the
  # instrument, the self-harm note, item 9's text and the score markup.
  SCREENING_CONTENT = [
    "PHQ-9", "Self-harm response recorded", "better off dead", "Item 9 indicates",
    "screening-score", "Severity band"
  ].freeze

  setup do
    @config = Rails.application.config.x.lakeraven_ehr
    @had_key = @config.key?(:open_disclosure_surfaces)
    @original_surfaces = @config.open_disclosure_surfaces
    # Read AND write scopes: a closed surface must 404 even for a token that
    # would otherwise be allowed through.
    setup_smart_auth(scopes: "system/*.read system/*.write")
    Lakeraven::EHR::ExportsController.reset_store!
    # The sign-on throttle and the request limiter are process-global.
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::RateLimit.reset!
    @forgery_was = ActionController::Base.allow_forgery_protection
  end

  teardown do
    if @had_key
      @config.open_disclosure_surfaces = @original_surfaces
    else
      @config.delete(:open_disclosure_surfaces)
    end
    ActionController::Base.allow_forgery_protection = @forgery_was
    teardown_smart_auth
    Lakeraven::EHR::ExportsController.reset_store!
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::RateLimit.reset!
    Lakeraven::EHR::ScreeningResponse.where(patient_dfn: PATIENT_DFN).delete_all
  end

  # Production posture for the reproduced sequence: CSRF enforced, so the
  # machine client has to fetch a token the way the reviewer did.
  def with_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = @forgery_was
  end

  def seed_bh_browser_user
    mock = RpmsRpc.client
    mock.seed_user(BH_BROWSER_DUZ, credentials: "#{BH_BROWSER_USER[:username]};#{BH_BROWSER_USER[:password]}",
      name: "BH,TESTUSER", role: :provider)
    mock.seed_held_keys(BH_BROWSER_DUZ, [ "AMHZMENU" ])
    mock.seed_options(BH_BROWSER_DUZ, [ "CIAV VUECENTRIC" ])
  end

  # A completed PHQ-9 for the synthetic patient, item 9 positive and
  # acknowledged, so its result page carries everything a closed surface
  # must withhold: total, band, every item answer and the self-harm note.
  def seed_phq9_screening
    Lakeraven::EHR::ScreeningResponse.where(patient_dfn: PATIENT_DFN).delete_all
    answers = PHQ9.link_ids.index_with { 1 }
    answers[PHQ9.safety_link_id] = 3
    Lakeraven::EHR::ScreeningResponse.create!(
      patient_dfn: PATIENT_DFN, encounter_ien: "2090061", instrument_key: PHQ9.key,
      answers: answers, total_score: answers.values.sum, severity_band: PHQ9.band_label_for(answers.values.sum),
      effective_at: Time.utc(2026, 3, 1), source: Lakeraven::EHR::ScreeningResponse::SOURCE_CLINICIAN,
      administered_by: BH_BROWSER_DUZ, safety_flagged: true,
      safety_acknowledged_at: Time.utc(2026, 3, 1), safety_acknowledged_by: BH_BROWSER_DUZ
    )
  end

  # The CSRF token from a page this session may load. Anonymous, GET /login
  # is the sign-in form; signed in, it may redirect, in which case the page
  # it lands on carries the token.
  def csrf_token_from_login_page
    get "/lakeraven-ehr/login"
    follow_redirect! while response.redirect?
    assert_response :ok, "GET /login must answer (got #{response.status})"
    token = response.body[/name="csrf-token" content="([^"]+)"/, 1]
    assert token.present?, "GET /login must carry a CSRF meta tag"
    token
  end

  def assert_no_screening_content(label)
    SCREENING_CONTENT.each do |text|
      refute_includes response.body, text, "#{label}: a closed surface must not carry the screening (#{text.inspect})"
    end
  end

  def open_surfaces(value)
    @config.open_disclosure_surfaces = value
  end

  # The clinician's browser surface: the real sign-on bridge (POST /login)
  # validates the seeded user against the mock RPMS, mints a browser-bound
  # SMART token and stashes it in the session. Every chart request that
  # follows on this integration session carries the cookie and NO
  # Authorization header.
  def sign_in_browser_session
    post "/lakeraven-ehr/login", params: BROWSER_USER
    assert_response :redirect, "setup: the seeded clinician must sign in (got #{response.status})"
  end

  # The behavioural-health clinician's browser session, with the patient's
  # record opened the way the web surface opens it: an audited POST on the
  # session, no Authorization header. A browser session may only write where
  # forgery protection is actually enforced (SmartAuthentication's landing
  # contract), so this runs with it ON, as in production, and carries the
  # CSRF token of a page the session loaded. Teardown restores the flag.
  def sign_in_bh_browser_session_with_open_context
    seed_bh_browser_user
    ActionController::Base.allow_forgery_protection = true
    post "/lakeraven-ehr/login", params: BH_BROWSER_USER.merge(authenticity_token: csrf_token_from_login_page)
    assert_response :redirect, "setup: the BH clinician must sign in (got #{response.status})"
    # Sign-on resets the session: a fresh token, not the pre-login one.
    post "/lakeraven-ehr/patients/#{PATIENT_DFN}/context", params: { authenticity_token: csrf_token_from_login_page }
    assert_response :redirect, "setup: the browser session must open the patient's record (got #{response.status})"
  end

  def screenings_index(headers = {})
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}/screenings", headers: headers
  end

  def screening_show(id, headers = {})
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}/screenings/#{id}", headers: headers
  end

  def allergy_form(headers = {})
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}/allergies/new", headers: headers
  end

  def assert_screenings_index_rendered(label)
    assert_response :ok, "#{label}: the screenings index must render (got #{response.status})"
    assert_equal "text/html", response.media_type, label
    assert_includes response.body, "PHQ-9", "#{label}: the index must list the seeded PHQ-9"
  end

  def assert_screening_result_rendered(row, label)
    assert_response :ok, "#{label}: the screening result must render (got #{response.status})"
    assert_equal "text/html", response.media_type, label
    assert_includes response.body, PHQ9.title, label
    assert_includes response.body, "Self-harm response recorded", "#{label}: the item-9 note must render"
    assert_includes response.body, "better off dead", "#{label}: item 9's text must render"
    assert_select "span.screening-score__number", text: row.total_score.to_s
  end

  def assert_html_chart_rendered(label)
    assert_response :ok, "#{label}: the HTML chart must render (got #{response.status})"
    assert_equal "text/html", response.media_type, label
    PATIENT_NAME_PARTS.each { |part| assert_includes response.body, part, label }
  end

  # -- Requests, one per route the switch governs ------------------------------

  def fhir_patient_read(headers = @headers)
    get "/lakeraven-ehr/Patient/#{PATIENT_DFN}", headers: headers
  end

  def fhir_condition_search(headers = @headers)
    get "/lakeraven-ehr/Condition", params: { patient: PATIENT_DFN }, headers: headers
  end

  def chart_json(headers = @headers)
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}.json", headers: headers
  end

  def chart_fhir_accept(headers = @headers)
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: headers.merge("Accept" => "application/fhir+json")
  end

  # The HTML chart as a MACHINE client reaches it: a bearer token, Accept
  # left to the default (no FHIR negotiation), so the representation is HTML.
  def chart_html(headers = @headers)
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: headers
  end

  # The HTML chart as a signed-in clinician's browser reaches it: cookie only.
  def chart_html_browser
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}"
  end

  # -- The dummy app's host-root chart route (/patients/:dfn, no engine prefix)

  def host_chart_html(headers = @headers)
    get "/patients/#{PATIENT_DFN}", headers: headers
  end

  def host_chart_html_browser
    get "/patients/#{PATIENT_DFN}"
  end

  def host_chart_json(headers = @headers)
    get "/patients/#{PATIENT_DFN}.json", headers: headers
  end

  def host_chart_format_param(headers = @headers)
    get "/patients/#{PATIENT_DFN}", params: { _format: "json" }, headers: headers
  end

  def host_chart_fhir_accept(headers = @headers)
    get "/patients/#{PATIENT_DFN}", headers: headers.merge("Accept" => "application/fhir+json")
  end

  # -- Test-only host routes straight at the engine controllers (gap B) ------

  def host_fhir_patient_read(headers = @headers)
    get "/host_fhir/Patient/#{PATIENT_DFN}", headers: headers
  end

  def host_fhir_condition_search(headers = @headers)
    get "/host_fhir/Condition", params: { patient: PATIENT_DFN }, headers: headers
  end

  def host_export_kickoff(headers = @headers)
    post "/host_exports", params: { export_type: "patient", patient_dfn: PATIENT_DFN }, headers: headers
  end

  def host_export_file(export_id, file_name, headers = @headers)
    get "/host_exports/#{export_id}/files/#{file_name}", headers: headers
  end

  def host_transition_of_care(headers = @headers)
    post "/host_transitions_of_care", params: { patient_dfn: PATIENT_DFN }, headers: headers
  end

  def export_kickoff(headers = @headers)
    post "/lakeraven-ehr/exports",
      params: { export_type: "patient", patient_dfn: PATIENT_DFN }, headers: headers
  end

  def transition_of_care(headers = @headers)
    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: PATIENT_DFN }, headers: headers
  end

  # Kick off an export while bulk_export is open and return the status URL
  # and the Patient NDJSON file path, so the closed-path tests have a real,
  # completed export to be refused.
  def completed_export_paths
    export_id, file_name = completed_export
    [ "/lakeraven-ehr/exports/#{export_id}", "/lakeraven-ehr/exports/#{export_id}/files/#{file_name}" ]
  end

  # The same completed export as [export_id, patient_file_name], for routes
  # that address it without the engine prefix. The export store is shared by
  # every route that reaches ExportsController, so an export kicked off
  # through the engine route is the one a host route serves.
  def completed_export
    open_surfaces [ :bulk_export ]
    export_kickoff
    assert_response :accepted, "setup: POST /exports must succeed while bulk_export is open"
    export_id = JSON.parse(response.body).fetch("id")

    get "/lakeraven-ehr/exports/#{export_id}", headers: @headers
    assert_response :ok, "setup: the export must complete while bulk_export is open"
    patient_file = JSON.parse(response.body).fetch("output").find { |f| f["type"] == "Patient" }
    assert patient_file, "setup: the manifest must list a Patient file"

    file_name = URI.parse(patient_file.fetch("url")).path.split("/").last
    [ export_id, file_name ]
  end

  # -- Assertions ---------------------------------------------------------------

  def assert_closed(label)
    assert_response :not_found, "#{label} should be 404 while its surface is closed (got #{response.status})"
    assert_no_clinical_content(label)
  end

  def assert_no_clinical_content(label)
    body = response.body
    PATIENT_NAME_PARTS.each do |part|
      refute_includes body, part, "#{label}: a closed surface must not carry the patient's name"
    end
    refute_match(/"resourceType"\s*:\s*"Patient"/, body, "#{label}: a closed surface must not carry a Patient resource")
    refute_match(/"resourceType"\s*:\s*"Bundle"/, body, "#{label}: a closed surface must not carry a Bundle")
    refute_includes body, "ClinicalDocument", "#{label}: a closed surface must not carry a C-CDA"
  end

  def assert_no_broker_calls_since(before, label)
    calls = RpmsRpc.client.received_calls.length - before
    assert_equal 0, calls, "#{label}: a closed surface must answer before any broker call (#{calls} made)"
  end

  def throttle_audit_rows
    Lakeraven::EHR::AuditEvent.where(outcome_desc: Lakeraven::EHR::RateLimit::AUDIT_DESCRIPTION)
  end

  # Run a request against a closed surface and assert every closed-surface
  # property at once.
  def assert_closed_request(label)
    before = RpmsRpc.client.received_calls.length
    yield
    assert_closed(label)
    assert_no_broker_calls_since(before, label)
  end

  # ============================================================================
  # (a) Everything closed (value nil)
  # ============================================================================

  test "nil: FHIR Patient read is 404 with no broker call and no clinical content" do
    open_surfaces nil
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
  end

  test "nil: FHIR Condition search is 404 with no broker call and no clinical content" do
    open_surfaces nil
    assert_closed_request("GET /Condition?patient=") { fhir_condition_search }
  end

  test "nil: the chart's .json representation is 404 with no broker call and no Bundle" do
    open_surfaces nil
    assert_closed_request("GET /patients/:dfn.json") { chart_json }
  end

  test "nil: the chart with Accept: application/fhir+json is 404 with no broker call and no Bundle" do
    open_surfaces nil
    assert_closed_request("GET /patients/:dfn Accept: fhir+json") { chart_fhir_accept }
  end

  test "nil: POST /exports is 404 with no broker call" do
    open_surfaces nil
    assert_closed_request("POST /exports") { export_kickoff }
  end

  test "nil: GET /exports/:id is 404 for a completed export with no broker call" do
    status_path, _file_path = completed_export_paths
    open_surfaces nil
    assert_closed_request("GET /exports/:id") { get status_path, headers: @headers }
  end

  test "nil: DELETE /exports/:id is 404 for a completed export with no broker call" do
    status_path, _file_path = completed_export_paths
    open_surfaces nil
    assert_closed_request("DELETE /exports/:id") { delete status_path, headers: @headers }
  end

  test "nil: GET /exports/:id/files/:file_name is 404 for a completed export and serves no bytes" do
    _status_path, file_path = completed_export_paths
    open_surfaces nil
    assert_closed_request("GET /exports/:id/files/patient.ndjson") { get file_path, headers: @headers }
    refute_equal "application/fhir+ndjson", response.media_type
  end

  test "nil: POST /transitions_of_care is 404 with no broker call and no C-CDA" do
    open_surfaces nil
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
    refute_equal "application/xml", response.media_type
  end

  # The two FHIR API calls routed outside the fhir_api block, on the FHIR base
  # and bearer-only: Measure/$import and the inbound C-CDA import. They are
  # fhir_api like every other call on that base (amendment 2, lead decision):
  # inbound C-CDA ingest drops Part 2 security labels today (Half 2 of #522),
  # so it must not run while the API is closed. Today both authenticate the
  # bearer and answer an OperationOutcome (400 for an empty body).
  def ccda_import(headers = @headers)
    post "/lakeraven-ehr/ccda_imports", headers: headers
  end

  def measure_import(headers = @headers)
    post "/lakeraven-ehr/Measure/$import", headers: headers
  end

  test "nil: POST /ccda_imports is 404 with no broker call" do
    open_surfaces nil
    assert_closed_request("POST /ccda_imports") { ccda_import }
    refute_match(/"resourceType"\s*:\s*"OperationOutcome"/, response.body,
      "POST /ccda_imports: a closed surface must not answer with an OperationOutcome")
  end

  test "nil: POST /Measure/$import is 404 with no broker call" do
    open_surfaces nil
    assert_closed_request("POST /Measure/$import") { measure_import }
    refute_match(/"resourceType"\s*:\s*"OperationOutcome"/, response.body,
      "POST /Measure/$import: a closed surface must not answer with an OperationOutcome")
  end

  # The other side, so the 404 is the switch's: with fhir_api open the same
  # bearer requests are answered (whatever they answer an empty body).
  test "fhir_api only: POST /ccda_imports and POST /Measure/$import are not 404" do
    open_surfaces [ :fhir_api ]
    ccda_import
    refute_equal 404, response.status, "POST /ccda_imports while fhir_api is open must not be 404"
    measure_import
    refute_equal 404, response.status, "POST /Measure/$import while fhir_api is open must not be 404"
  end

  # Closed means closed BEFORE authentication: an unauthenticated request gets
  # the same 404, not a 401 that confirms the surface exists.
  test "nil: a closed surface answers 404, not 401, to a request with no token" do
    open_surfaces nil
    assert_closed_request("GET /Patient/:dfn no token") { fhir_patient_read({}) }
    assert_closed_request("POST /exports no token") { export_kickoff({}) }
    assert_closed_request("POST /transitions_of_care no token") { transition_of_care({}) }
  end

  # ============================================================================
  # (b) Everything closed: the HTML chart and the metadata endpoints stay on
  # ============================================================================

  # The clinician's browser surface, reached the way a browser reaches it:
  # the session the sign-on bridge established, no Authorization header.
  # Pins behaviour that must not regress (passes today).
  test "nil: the HTML chart still renders the patient for a browser session with no Authorization header" do
    sign_in_browser_session
    open_surfaces nil

    chart_html_browser
    assert_html_chart_rendered("GET /lakeraven-ehr/patients/:dfn (browser session)")

    host_chart_html_browser
    assert_html_chart_rendered("GET /patients/:dfn (browser session, host root)")
  end

  # ============================================================================
  # Gap A: a bearer token must not read the HTML chart while fhir_api is closed
  # ============================================================================

  # A Backend Services system token or a SMART-launched app's token asking
  # for text/html is a machine reading the chart: API egress by another name.
  # While fhir_api is closed it is refused exactly like a closed surface.
  test "nil: a bearer token on the HTML chart is 404 with no broker call and no clinical content" do
    open_surfaces nil
    assert_closed_request("GET /lakeraven-ehr/patients/:dfn Bearer, text/html") { chart_html }
    assert_closed_request("GET /patients/:dfn Bearer, text/html (host root)") { host_chart_html }
  end

  # Gap F (amendment 2). Only a header SmartAuthentication would authenticate
  # FROM counts: scheme `Bearer`, case-insensitive, whatever the token's
  # value. The refusal is decided on the header's shape before authentication,
  # not on an authentication outcome, so an unknown token is refused like a
  # valid one — never a 401 that confirms a surface worth authenticating
  # against. A `Basic` header (a proxy's) is "no bearer found" and falls
  # through to the session exactly as extract_bearer_token does, so a
  # signed-in browser behind such a proxy keeps its chart and its screenings.
  test "nil: a Bearer Authorization header on the HTML chart is 404 before authentication; a Basic header falls through to the session" do
    seed_phq9_screening
    sign_in_bh_browser_session_with_open_context
    open_surfaces nil

    basic = { "Authorization" => "Basic #{Base64.strict_encode64('proxy:secret')}" }
    chart_html(basic)
    assert_html_chart_rendered("GET /lakeraven-ehr/patients/:dfn Basic header + session")
    host_chart_html(basic)
    assert_html_chart_rendered("GET /patients/:dfn Basic header + session (host root)")
    screenings_index(basic)
    assert_screenings_index_rendered("GET /lakeraven-ehr/patients/:dfn/screenings Basic header + session")

    junk = { "Authorization" => "Bearer not-a-token" }
    assert_closed_request("GET /lakeraven-ehr/patients/:dfn junk bearer + session") { chart_html(junk) }
    assert_closed_request("GET /patients/:dfn junk bearer + session (host root)") { host_chart_html(junk) }

    # The scheme match is case-insensitive, as extract_bearer_token's is: a
    # lower-case `bearer` carrying a VALID system token is still a header
    # token, and is refused on the chart and on the screenings alike.
    lower = { "Authorization" => @headers["Authorization"].sub(/\ABearer/, "bearer") }
    assert_match(/\Abearer /, lower["Authorization"])
    assert_closed_request("GET /lakeraven-ehr/patients/:dfn lower-case bearer + session") { chart_html(lower) }
    assert_closed_request("GET /patients/:dfn lower-case bearer + session (host root)") { host_chart_html(lower) }
    assert_closed_request("GET /lakeraven-ehr/patients/:dfn/screenings lower-case bearer + session") { screenings_index(lower) }
    assert_no_screening_content("GET /lakeraven-ehr/patients/:dfn/screenings lower-case bearer + session")
  end

  # The other side of the rule, pinned so the refusal cannot grow into a
  # blanket one: a bearer HTML chart behaves as today while fhir_api is open.
  test "fhir_api only: a bearer token still renders the HTML chart" do
    open_surfaces [ :fhir_api ]

    chart_html
    assert_html_chart_rendered("GET /lakeraven-ehr/patients/:dfn Bearer")

    host_chart_html
    assert_html_chart_rendered("GET /patients/:dfn Bearer (host root)")
  end

  # ============================================================================
  # Gap E: the header-token rule covers every surface that authenticates one
  # ============================================================================

  # The reviewer's reproduction, step for step, with forgery protection ON as
  # in production: a Backend Services token and no human sign-on. Today step
  # 2 answers 302 (the context opens), step 3 renders the PHQ-9 result page
  # and its index, and step 4 renders the allergy form. Each must be the
  # closed surface's 404: before authentication, before the CSRF check has a
  # side effect (no context is opened on the session), before any broker
  # call, and with no screening content in the body.
  test "nil: a bearer-only machine client is refused the patient context, the screenings and the allergy form (forgery protection on)" do
    with_forgery_protection do
      row = seed_phq9_screening
      open_surfaces nil

      # 1. Anonymous: the sign-in page hands out a CSRF token and a session cookie.
      csrf = csrf_token_from_login_page

      # 2. The bearer plus that token: today 302 (context opened).
      assert_closed_request("POST /patients/:dfn/context Bearer + authenticity_token") do
        post "/lakeraven-ehr/patients/#{PATIENT_DFN}/context",
          params: { authenticity_token: csrf }, headers: @headers
      end
      assert_nil session[CONTEXT_SESSION_KEY],
        "POST /patients/:dfn/context: a refused request must not open a patient context on the session"

      # 3. The screening result and index with the bearer and the cookie: today 200 text/html.
      assert_closed_request("GET /patients/:dfn/screenings/:id Bearer + cookie") { screening_show(row.id, @headers) }
      assert_no_screening_content("GET /patients/:dfn/screenings/:id Bearer + cookie")
      assert_closed_request("GET /patients/:dfn/screenings Bearer + cookie") { screenings_index(@headers) }
      assert_no_screening_content("GET /patients/:dfn/screenings Bearer + cookie")

      # 4. The allergy form: today 200.
      assert_closed_request("GET /patients/:dfn/allergies/new Bearer + cookie") { allergy_form(@headers) }
      refute_includes response.body, "<form", "GET /patients/:dfn/allergies/new: a closed surface must not render the form"
    end
  end

  # The other side, so the 404s above are the switch's and not some other
  # refusal: with fhir_api open the same bearer requests are answered (not
  # 404), as they are today. Pinned loosely — "not 404" — because what a
  # system token may do on these surfaces while the API is open is their own
  # specs' business, not this switch's.
  test "fhir_api only: the same bearer requests are not 404 (the refusal is the switch's)" do
    with_forgery_protection do
      row = seed_phq9_screening
      open_surfaces [ :fhir_api ]

      csrf = csrf_token_from_login_page
      post "/lakeraven-ehr/patients/#{PATIENT_DFN}/context", params: { authenticity_token: csrf }, headers: @headers
      refute_equal 404, response.status, "POST /patients/:dfn/context Bearer while fhir_api is open must not be 404"

      screening_show(row.id, @headers)
      refute_equal 404, response.status, "GET /patients/:dfn/screenings/:id Bearer while fhir_api is open must not be 404"

      allergy_form(@headers)
      refute_equal 404, response.status, "GET /patients/:dfn/allergies/new Bearer while fhir_api is open must not be 404"
    end
  end

  # Path 1 must keep working: the clinician's browser session, no
  # Authorization header, opens the record and reads the screenings while
  # everything is closed. Pins behaviour that must not regress (passes today).
  test "nil: a signed-in browser session with no Authorization header still opens a context and reads the screenings" do
    row = seed_phq9_screening
    open_surfaces nil

    sign_in_bh_browser_session_with_open_context
    assert_equal PATIENT_DFN, session[CONTEXT_SESSION_KEY].to_s, "the browser session must hold the open record"

    screenings_index
    assert_screenings_index_rendered("GET /patients/:dfn/screenings (browser session)")

    screening_show(row.id)
    assert_screening_result_rendered(row, "GET /patients/:dfn/screenings/:id (browser session)")

    allergy_form
    assert_response :ok, "GET /patients/:dfn/allergies/new (browser session) must render (got #{response.status})"
  end

  test "nil: GET /metadata still answers 200" do
    open_surfaces nil
    get "/lakeraven-ehr/metadata"
    assert_response :ok
    assert_equal "CapabilityStatement", JSON.parse(response.body)["resourceType"]
  end

  test "nil: GET /.well-known/smart-configuration still answers 200" do
    open_surfaces nil
    get "/lakeraven-ehr/.well-known/smart-configuration"
    assert_response :ok
    assert JSON.parse(response.body).key?("token_endpoint")
  end

  # ============================================================================
  # (c) Only fhir_api open (String entry)
  # ============================================================================

  test "fhir_api only: FHIR Patient read works" do
    open_surfaces [ "fhir_api" ]
    fhir_patient_read
    assert_response :ok
    assert_equal "Patient", JSON.parse(response.body)["resourceType"]
  end

  test "fhir_api only: the chart's FHIR JSON representation works" do
    open_surfaces [ "fhir_api" ]
    chart_json
    assert_response :ok
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
  end

  test "fhir_api only: POST /exports is 404" do
    open_surfaces [ "fhir_api" ]
    assert_closed_request("POST /exports") { export_kickoff }
  end

  test "fhir_api only: POST /transitions_of_care is 404" do
    open_surfaces [ "fhir_api" ]
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  # ============================================================================
  # (d) Only bulk_export open (Symbol entry)
  # ============================================================================

  test "bulk_export only: POST /exports works" do
    open_surfaces [ :bulk_export ]
    export_kickoff
    assert_response :accepted
    assert JSON.parse(response.body)["id"].present?
  end

  test "bulk_export only: FHIR Patient read is 404" do
    open_surfaces [ :bulk_export ]
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
  end

  test "bulk_export only: the chart's FHIR JSON representation is 404" do
    open_surfaces [ :bulk_export ]
    assert_closed_request("GET /patients/:dfn.json") { chart_json }
  end

  test "bulk_export only: POST /transitions_of_care is 404" do
    open_surfaces [ :bulk_export ]
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  # ============================================================================
  # (e) Only ccda open
  # ============================================================================

  test "ccda only: POST /transitions_of_care works" do
    open_surfaces [ :ccda ]
    transition_of_care
    assert_response :created
    assert_equal "application/xml", response.media_type
    assert_includes response.body, "ClinicalDocument"
  end

  test "ccda only: FHIR Patient read is 404" do
    open_surfaces [ :ccda ]
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
  end

  test "ccda only: POST /exports is 404" do
    open_surfaces [ :ccda ]
    assert_closed_request("POST /exports") { export_kickoff }
  end

  # ============================================================================
  # (f) A non-Array value closes all three
  # ============================================================================

  test "true closes all three surfaces" do
    open_surfaces true
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
    assert_closed_request("POST /exports") { export_kickoff }
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  test "a bare surface name String closes all three surfaces" do
    open_surfaces "fhir_api"
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
    assert_closed_request("POST /exports") { export_kickoff }
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  test "an unknown name opens nothing" do
    open_surfaces [ :everything ]
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
    assert_closed_request("POST /exports") { export_kickoff }
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  # ============================================================================
  # Gap B: host routes pointing straight at the engine controllers
  # ============================================================================

  # The dummy app already draws /patients/:dfn at the host root. Every FHIR
  # negotiation of it is fhir_api egress and must 404 while fhir_api is closed.
  test "nil: the host-root chart's FHIR representations are 404 with no broker call" do
    open_surfaces nil
    assert_closed_request("GET /patients/:dfn.json (host root)") { host_chart_json }
    assert_closed_request("GET /patients/:dfn?_format=json (host root)") { host_chart_format_param }
    assert_closed_request("GET /patients/:dfn Accept: fhir+json (host root)") { host_chart_fhir_accept }
  end

  test "nil: host routes at the FHIR resource controllers are 404 with no broker call" do
    open_surfaces nil
    assert_closed_request("GET /host_fhir/Patient/:dfn") { host_fhir_patient_read }
    assert_closed_request("GET /host_fhir/Condition?patient=") { host_fhir_condition_search }
  end

  test "nil: a host route at the exports controller is 404 with no broker call" do
    open_surfaces nil
    assert_closed_request("POST /host_exports") { host_export_kickoff }
  end

  test "nil: a host route at the export files controller is 404 for a completed export and serves no bytes" do
    export_id, file_name = completed_export
    open_surfaces nil
    assert_closed_request("GET /host_exports/:export_id/files/:file_name") { host_export_file(export_id, file_name) }
    refute_equal "application/fhir+ndjson", response.media_type
  end

  test "nil: a host route at the transitions of care controller is 404 with no broker call and no C-CDA" do
    open_surfaces nil
    assert_closed_request("POST /host_transitions_of_care") { host_transition_of_care }
    refute_equal "application/xml", response.media_type
  end

  # Each surface governs its own controllers, host route or engine route: a
  # host route at an exports controller is bulk_export, not fhir_api.
  test "fhir_api only: host routes at the export and C-CDA controllers are still 404" do
    open_surfaces [ :fhir_api ]
    assert_closed_request("POST /host_exports") { host_export_kickoff }
    assert_closed_request("POST /host_transitions_of_care") { host_transition_of_care }
  end

  test "bulk_export only: host routes at the FHIR resource and C-CDA controllers are still 404" do
    open_surfaces [ :bulk_export ]
    assert_closed_request("GET /host_fhir/Patient/:dfn") { host_fhir_patient_read }
    assert_closed_request("POST /host_transitions_of_care") { host_transition_of_care }
  end

  # With the matching surface open, a host route behaves as the engine route
  # does. Pins behaviour that must not regress (passes today).
  test "open: host routes at the governed controllers behave as the engine routes" do
    open_surfaces ALL_SURFACES

    host_fhir_patient_read
    assert_response :ok, "GET /host_fhir/Patient/:dfn while fhir_api is open"
    assert_equal "Patient", JSON.parse(response.body)["resourceType"]

    host_fhir_condition_search
    assert_response :ok, "GET /host_fhir/Condition while fhir_api is open"
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]

    host_chart_json
    assert_response :ok, "GET /patients/:dfn.json while fhir_api is open"
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]

    host_export_kickoff
    assert_response :accepted, "POST /host_exports while bulk_export is open"
    assert JSON.parse(response.body)["id"].present?

    export_id, file_name = completed_export
    open_surfaces ALL_SURFACES
    host_export_file(export_id, file_name)
    assert_response :ok, "GET /host_exports/:export_id/files/:file_name while bulk_export is open"
    assert_equal "application/fhir+ndjson", response.media_type

    host_transition_of_care
    assert_response :created, "POST /host_transitions_of_care while ccda is open"
    assert_equal "application/xml", response.media_type
    assert_includes response.body, "ClinicalDocument"
  end

  # ============================================================================
  # Gap C: a closed surface answers 404 before the rate limiter
  # ============================================================================

  # A client that has spent its whole budget on the surface while it was
  # open, then meets it closed: 404, not a 429 that confirms the surface
  # exists, and no rate-limit audit row. The budget is spent with exactly
  # `limit` permitted requests (no 429 beforehand), because the limiter
  # writes its audit row only on the FIRST refusal per key and window — a
  # probe 429 would consume that and hide a row written by the closed request.
  # The client's over-limit state is proven afterwards, by reopening.
  def assert_closed_before_rate_limit(label, limit:)
    with_test_rate_limit(max_requests: limit) do
      limit.times do |n|
        yield
        assert_response :ok, "#{label}: request #{n + 1} of #{limit} must be served while the surface is open"
      end
      Lakeraven::EHR::AuditEvent.delete_all

      open_surfaces nil
      assert_closed_request("#{label} over the rate limit") { yield }
      refute_equal "application/fhir+json", response.media_type,
        "#{label}: a closed surface must not answer with an OperationOutcome"
      refute_includes response.body, "throttled", "#{label}: a closed surface must not say it is throttled"
      assert_equal 0, throttle_audit_rows.count,
        "#{label}: a closed surface must write no rate-limit audit row"

      open_surfaces [ :fhir_api ]
      yield
      assert_response :too_many_requests,
        "#{label}: the client must have been over its limit when the closed surface answered 404"
    end
  end

  test "closed fhir_api: the host-root chart .json answers 404, not 429, to a client over the rate limit" do
    open_surfaces [ :fhir_api ]
    assert_closed_before_rate_limit("GET /patients/:dfn.json (host root)", limit: 2) { host_chart_json }
  end

  test "closed fhir_api: a host route at the FHIR Patient controller answers 404, not 429, to a client over the rate limit" do
    open_surfaces [ :fhir_api ]
    assert_closed_before_rate_limit("GET /host_fhir/Patient/:dfn", limit: 2) { host_fhir_patient_read }
  end

  # ============================================================================
  # The switch is read per request
  # ============================================================================

  test "the value is read per request: closing fhir_api takes effect on the next request" do
    open_surfaces ALL_SURFACES
    fhir_patient_read
    assert_response :ok

    open_surfaces nil
    assert_closed_request("GET /Patient/:dfn after closing") { fhir_patient_read }

    open_surfaces [ :fhir_api ]
    fhir_patient_read
    assert_response :ok
  end
end
