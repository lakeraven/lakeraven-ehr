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
  end

  teardown do
    if @had_key
      @config.open_disclosure_surfaces = @original_surfaces
    else
      @config.delete(:open_disclosure_surfaces)
    end
    teardown_smart_auth
    Lakeraven::EHR::ExportsController.reset_store!
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::RateLimit.reset!
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

  # ANY Authorization header, whatever its scheme or value: the refusal is a
  # routing decision on the header's presence, not an authentication outcome.
  # Even a signed-in browser session is refused when a header rides along.
  test "nil: any Authorization header on the HTML chart is 404 before authentication" do
    sign_in_browser_session
    open_surfaces nil

    basic = { "Authorization" => "Basic #{Base64.strict_encode64('proxy:secret')}" }
    assert_closed_request("GET /lakeraven-ehr/patients/:dfn Basic header + session") { chart_html(basic) }
    assert_closed_request("GET /patients/:dfn Basic header + session (host root)") { host_chart_html(basic) }

    # Not a 401 that confirms a surface worth authenticating against.
    junk = { "Authorization" => "Bearer not-a-token" }
    assert_closed_request("GET /lakeraven-ehr/patients/:dfn junk bearer") { chart_html(junk) }
    assert_closed_request("GET /patients/:dfn junk bearer (host root)") { host_chart_html(junk) }
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
