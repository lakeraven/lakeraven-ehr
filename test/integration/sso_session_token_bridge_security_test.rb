# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/authentication"

# Reproductions for the adversarial review of the SSO session->token bridge
# (PR #486, rounds 1 and 2). Every test here failed before the corresponding
# fix; each names the finding it reproduces.
#
# Seeded users (test_helper): 301 PROVIDER,TEST (no keys) / 303 CLERK,TEST
# (no keys) / 304 RODRIGUEZ,LINDA (prc_supervisor + cprs_gui_chart).
class SsoSessionTokenBridgeSecurityTest < ActionDispatch::IntegrationTest
  LOGIN = "/lakeraven-ehr/login"

  # The throttle is process-global by design (see LoginThrottle); tests must
  # not inherit each other's failed attempts.
  setup { Lakeraven::EHR::LoginThrottle.reset! }
  teardown { Lakeraven::EHR::LoginThrottle.reset! }

  def sign_in(username = "lindarodriguez", password = "test123")
    post LOGIN, params: { username: username, password: password }
  end

  def session_token
    Doorkeeper::AccessToken.order(:id).last
  end

  # -- B2: the token is bound to nothing ------------------------------------

  # Capture the token minted for a browser session, throw the cookie jar away,
  # and replay it as a Bearer header. It must not work: the credential belongs
  # to a session and to the human that session signed in.
  test "a session token replayed from a foreign session is refused" do
    sign_in
    token = session_token
    plaintext = token.plaintext_token || token.token

    reset! # fresh cookie jar — no session at all

    get "/lakeraven-ehr/patients/1", headers: { "Authorization" => "Bearer #{plaintext}" }
    assert_response :unauthorized
  end

  test "the session token records the DUZ it was minted for" do
    sign_in
    assert_equal "304", session_token.resource_owner_id.to_s
  end

  # A session whose DUZ no longer matches the token it carries is not the
  # session that token was minted for.
  test "a session token is refused when the session DUZ does not match it" do
    sign_in
    token = session_token
    token.update!(resource_owner_id: 999)

    get "/lakeraven-ehr/patients/1"
    assert_response :unauthorized
  end

  # -- B1: deny-by-default scopes from security keys ------------------------

  test "a user with no security keys receives no clinical scopes" do
    sign_in("testclerk", "test123")

    assert_equal "", session_token.scopes.to_s.strip
  end

  test "a user with no security keys cannot read a chart" do
    sign_in("testclerk", "test123")

    get "/lakeraven-ehr/patients/1"
    assert_response :forbidden
  end

  test "a clerk with no keys receives strictly less than a keyed provider" do
    sign_in("testclerk", "test123")
    clerk_scopes = session_token.scopes.to_a

    reset!
    sign_in
    keyed_scopes = session_token.scopes.to_a

    assert_empty clerk_scopes
    assert_includes keyed_scopes, "user/Patient.read"
    assert (clerk_scopes - keyed_scopes).empty?
  end

  test "no key in the registry confers a write scope by accident" do
    granted = Lakeraven::EHR::SessionScopePolicy.scopes_for(security_keys: [])

    assert_empty granted, "absence of keys must never confer privilege"
  end

  # -- H4 (round 2): read scopes must not authorize writes ------------------

  test "a read-only token cannot POST a C-CDA import" do
    setup_read_only_header_auth

    post "/lakeraven-ehr/ccda_imports", params: { patient_dfn: "1" },
      headers: @headers.merge("CONTENT_TYPE" => "application/xml"), env: { "RAW_POST_DATA" => "<ClinicalDocument/>" }
    assert_response :forbidden
  end

  test "a read-only token cannot create an export" do
    setup_read_only_header_auth

    post "/lakeraven-ehr/exports", params: { export_type: "patient" }, headers: @headers
    assert_response :forbidden
  end

  test "a read-only token cannot delete an export" do
    setup_read_only_header_auth

    delete "/lakeraven-ehr/exports/anything", headers: @headers
    assert_response :forbidden
  end

  test "a read-only token cannot request an eligibility check" do
    setup_read_only_header_auth

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" }, headers: @headers
    assert_response :forbidden
  end

  test "a read-only token cannot generate a transition-of-care document" do
    setup_read_only_header_auth

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :forbidden
  end

  # -- H3 (round 2): patient binding on indexes and searches ----------------

  test "a patient-bound token cannot read another patient through the index" do
    setup_patient_bound_auth(dfn: 999)

    get "/lakeraven-ehr/Patient", headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token cannot read another patient's observations" do
    setup_patient_bound_auth(dfn: 999)

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token cannot read another patient's conditions" do
    setup_patient_bound_auth(dfn: 999)

    get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token reads its own compartment" do
    setup_patient_bound_auth(dfn: 1)

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :ok
  end

  # -- M (round 2): revinclude must respect the included type's scope -------

  test "revinclude does not return Provenance to a Patient-only token" do
    seed_provenance
    setup_header_auth(scopes: "user/Patient.read")

    get "/lakeraven-ehr/Patient", params: { _revinclude: "Provenance:target" }, headers: @headers
    assert_response :ok
    types = JSON.parse(response.body).fetch("entry", []).map { |e| e.dig("resource", "resourceType") }
    refute_includes types, "Provenance"
  end

  test "revinclude does return Provenance when the token may read it" do
    seed_provenance
    setup_header_auth(scopes: "user/Patient.read user/Provenance.read")

    get "/lakeraven-ehr/Patient", params: { _id: "1", _revinclude: "Provenance:target" }, headers: @headers
    assert_response :ok
    types = JSON.parse(response.body).fetch("entry", []).map { |e| e.dig("resource", "resourceType") }
    assert_includes types, "Provenance"
  end

  test "a patient-bound token cannot read another patient's service requests" do
    setup_patient_bound_auth(dfn: 999)

    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
    assert_response :forbidden
  end

  # -- B5: bulk-export ownership isolation ----------------------------------

  # B5 reported that a shared Doorkeeper application made one clinician's
  # `application.uid` compare equal to another's, so the export ownership
  # guard passed for the wrong human. After deny-by-default scopes that is no
  # longer REACHABLE from a browser session: no security key maps to an Export
  # scope, so a signed-in clinician cannot create or read one at all. This
  # pins that, and ExportsController keys ownership on the DUZ regardless, so
  # the guard does not silently become wrong the day an Export scope exists.
  test "a browser session cannot create a bulk export at all" do
    sign_in

    post "/lakeraven-ehr/exports", params: { export_type: "patient" }
    # Refused one step earlier than when this was written: a session-derived
    # token may not drive ANY state-changing API request (round 3, finding c),
    # so it never reaches the scope check that used to refuse it.
    assert_response :unauthorized
  end

  # -- B3: sign-out must revoke ---------------------------------------------

  test "sign-out revokes the token server-side, not just the cookie" do
    sign_in
    token = session_token

    delete "/lakeraven-ehr/logout"

    assert token.reload.revoked?, "the token outlived the session that minted it"
  end

  # -- C2 (rpms-rpc#235) — the EHR half of the concurrency fix --------------

  # The gem now serializes the RPCs it issues itself, but this app's sign-on
  # spans SEVERAL calls into it: authenticate, then user_info, then
  # ORWU USERKEYS. A second sign-on landing between them hands this one the
  # other clinician's name and security keys — i.e. their scopes. The whole
  # sequence has to be one unit, not three locked ones.
  test "sign-on holds the broker wire lock across its whole sequence" do
    held = []
    locked = false

    fake = Object.new
    fake.define_singleton_method(:synchronize_wire) do |&blk|
      locked = true
      begin
        blk.call
      ensure
        locked = false
      end
    end

    RpmsRpc.singleton_class.define_method(:synchronize_wire) do |&blk|
      fake.synchronize_wire(&blk)
    end

    original = RpmsRpc::Authentication.method(:user_security_keys)
    RpmsRpc::Authentication.define_singleton_method(:user_security_keys) do |duz|
      held << locked
      original.call(duz)
    end

    Lakeraven::EHR::AuthenticationService.new.authenticate(
      access_code: "lindarodriguez", verify_code: "test123"
    )

    assert_equal [ true ], held,
      "the security-key lookup ran outside the sign-on's lock"
  ensure
    RpmsRpc::Authentication.singleton_class.send(:remove_method, :user_security_keys)
    RpmsRpc.singleton_class.send(:remove_method, :synchronize_wire)
  end

  # -- M6: unbounded token growth -------------------------------------------

  # Signing in again is not a reason to leave the previous credential live.
  # Three sign-ins used to leave three usable 12-hour tokens, none of which
  # the clinician could revoke.
  test "signing in again revokes the previous session token" do
    sign_in
    first = session_token

    reset!
    sign_in

    assert first.reload.revoked?, "the previous session token is still live"
    assert_equal 1, Doorkeeper::AccessToken.where(resource_owner_id: 304, revoked_at: nil).count
  end

  # -- B4: audit identity ----------------------------------------------------

  test "an audited access records the signed-in clinician, not the shared application" do
    sign_in
    Lakeraven::EHR::AuditEvent.delete_all

    get "/lakeraven-ehr/patients/1"
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "304", event.agent_who_identifier
    assert_equal "RODRIGUEZ,LINDA", event.agent_name
  end

  # -- H2: the access code must not reach the logs --------------------------

  test "the access code is filtered from request logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    filtered = filter.filter("username" => "lindarodriguez", "password" => "test123")

    assert_equal "[FILTERED]", filtered["username"]
    assert_equal "[FILTERED]", filtered["password"]
  end

  # -- H1: verify_needs_change ----------------------------------------------

  test "a verify code flagged for change does not yield a signed-in session" do
    RpmsRpc.client.seed_lines(:av_code, "MUSTCHANGE;TEST123", {
      duz: 304, error_code: 0, verify_needs_change: 1, message: "Change it", user_class: 3
    })

    sign_in("mustchange", "test123")

    assert_nil session[:duz]
    assert_nil session[:smart_token]
  end

  # -- H3 (round 1): login throttling ---------------------------------------

  test "repeated failed logins are throttled before RPMS three-strike lockout" do
    attempts = Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS
    attempts.times { sign_in("lindarodriguez", "wrongwrong") }

    sign_in("lindarodriguez", "wrongwrong")
    assert_response :too_many_requests
  end

  test "throttling blocks even a correct credential once tripped" do
    Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS.times { sign_in("lindarodriguez", "wrongwrong") }

    sign_in
    assert_response :too_many_requests
    assert_nil session[:duz]
  end

  # -- M4: a failed login must not leave an existing session standing -------

  test "a failed login clears any session already established" do
    sign_in
    assert session[:duz].present?

    sign_in("lindarodriguez", "wrongwrong")

    assert_nil session[:duz]
  end

  # -- M3: a broker outage is a handled failure, not a 500 ------------------

  test "a broker outage renders a sign-in failure rather than an exception" do
    down = Object.new
    def down.authenticate(**) = raise(RpmsRpc::Client::ConnectionError, "broker down")

    with_singleton(Lakeraven::EHR::AuthenticationService, :new, ->(*) { down }) do
      sign_in
      assert_response :service_unavailable
      assert_nil session[:duz]
    end
  end

  # -- M2: session timeout ---------------------------------------------------

  test "an idle session past the timeout is signed out" do
    sign_in
    travel(Lakeraven::EHR::SessionsController::IDLE_TIMEOUT + 1.minute) do
      get "/lakeraven-ehr/patients/1"
      assert_response :unauthorized
    end
  end

  # -- M1/#13: the login form is not test-only ------------------------------

  test "the login form renders outside the test environment" do
    with_singleton(Rails.env, :test?, -> { false }) { get LOGIN }

    assert_response :ok
    assert_includes response.body, "name=\"username\""
    assert_includes response.body, "name=\"password\""
  end

  # =======================================================================
  # Round 3 — the two worst are consequences of round 2's own fixes.
  # =======================================================================

  # -- B1: compartment binding landed on :index, so every POST was unbound --

  # Round 2 refused `GET /Observation?patient=1` from a token bound to 999.
  # This is the same read through a different verb: a `patient_dfn` parameter
  # is not a control anywhere it appears, and this one returns a complete
  # C-CDA — name, DOB, address, allergies, conditions, medications.
  test "a patient-bound token cannot generate a transition of care for another patient" do
    setup_patient_bound_auth(dfn: 999, scopes: "patient/*.read patient/*.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :forbidden
    refute_includes response.body, "Anderson"
  end

  test "a patient-bound token cannot run an eligibility check for another patient" do
    setup_patient_bound_auth(dfn: 999, scopes: "patient/*.read patient/*.write")

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token cannot export another patient" do
    setup_patient_bound_auth(dfn: 999, scopes: "patient/*.read patient/*.write")

    post "/lakeraven-ehr/exports", params: { patient_dfn: "1" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token may still act within its own compartment" do
    setup_patient_bound_auth(dfn: 1, scopes: "patient/*.read patient/*.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :created
  end

  # -- B1b: the verb fix INVERTED authorization on read-as-POST routes -----

  # TransitionsOfCare and Export are reads shaped as POSTs. Dispatching purely
  # on verb made them require write and stop requiring read, so a write-only
  # token reads a chart it cannot reach through any read endpoint.
  test "a write-only token cannot generate a transition of care" do
    setup_header_auth(scopes: "system/*.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :forbidden
    refute_includes response.body, "Anderson"
  end

  test "a write-only token cannot create an export" do
    setup_header_auth(scopes: "system/*.write")

    post "/lakeraven-ehr/exports", params: { export_type: "patient" }, headers: @headers
    assert_response :forbidden
  end

  test "a read-and-write token can still use the read-as-POST routes" do
    setup_header_auth(scopes: "system/*.read system/*.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :created
  end

  # -- B3: ownership was missing from the endpoint that serves the bytes ---

  test "one client cannot download another client's export files" do
    seed_victim_export
    setup_header_auth(scopes: "system/*.read system/*.write") # a different client

    get "/lakeraven-ehr/exports/victim-export/files/PatientNdjson", headers: @headers

    assert_response :forbidden
    refute_includes response.body, "111-11-1111"
  end

  test "one client cannot delete another client's export" do
    seed_victim_export
    setup_header_auth(scopes: "system/*.read system/*.write") # a different client

    delete "/lakeraven-ehr/exports/victim-export", headers: @headers

    assert_response :forbidden
    assert Lakeraven::EHR::ExportsController.store.key?("victim-export"), "the export was removed anyway"
  end

  test "a client can still reach its own export files" do
    seed_victim_export(owner: "owner-client")
    setup_header_auth(scopes: "system/*.read system/*.write")
    @headers["X-Owner"] = "owner-client"

    # Ownership keys on the token's application uid, so re-seed the export to
    # this client rather than faking a header.
    Lakeraven::EHR::ExportsController.store["victim-export"].client_id =
      Doorkeeper::AccessToken.order(:id).last.application.uid

    get "/lakeraven-ehr/exports/victim-export/files/PatientNdjson", headers: @headers
    assert_response :ok
    assert_includes response.body, "111-11-1111"
  end

  # -- H1: one valid credential reset the IP limb of the throttle ---------

  # The IP limb exists precisely to stop spraying. Clearing it on any success
  # means an attacker who controls ONE account can spray indefinitely — and
  # with it goes the protection against tripping RPMS's shared broker-IP
  # three-strike lock for every clinician at once.
  test "a valid login does not clear the throttle for the addresses it sprayed" do
    victims = %w[testprovider testnurse testclerk]

    victims.each { |v| Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS.times { sign_in(v, "wrongwrong") } }
    sign_in # the attacker's own good credential

    sign_in("testprovider", "wrongwrong")
    assert_response :too_many_requests
  end

  test "a valid login does clear the throttle for its own account" do
    (Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS - 1).times { sign_in("lindarodriguez", "wrongwrong") }
    sign_in
    assert_response :redirect

    reset!
    sign_in
    assert_response :redirect
  end

  # -- H2: a denied access left no trace at all ---------------------------

  # record_audit_event was an after_action, and Rails skips those when a
  # before-callback halts — so exactly the refusals this PR introduced were
  # the ones that went unrecorded. A clinician probing charts outside their
  # compartment left nothing behind.
  test "a forbidden access is audited, with the reason" do
    setup_patient_bound_auth(dfn: 999)
    Lakeraven::EHR::AuditEvent.delete_all

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :forbidden

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "a refused access left no audit trail"
    assert_equal "4", event.outcome
    assert_match(/patient context/i, event.outcome_desc.to_s)
  end

  test "an unauthenticated access is audited" do
    Lakeraven::EHR::AuditEvent.delete_all

    get "/lakeraven-ehr/Observation", params: { patient: "1" }
    assert_response :unauthorized

    refute_nil Lakeraven::EHR::AuditEvent.order(:id).last, "a rejected credential left no audit trail"
  end

  # -- H3: idle timeout on one surface; revocation full of holes ----------

  test "an idle session past the timeout cannot reach the dashboard" do
    sign_in
    travel(Lakeraven::EHR::SessionsController::IDLE_TIMEOUT + 1.minute) do
      get "/lakeraven-ehr/dashboard"
      assert_response :redirect
    end
  end

  test "an idle session past the timeout has its token revoked" do
    sign_in
    token = session_token

    travel(Lakeraven::EHR::SessionsController::IDLE_TIMEOUT + 1.minute) do
      get "/lakeraven-ehr/patients/1"
      assert_response :unauthorized
    end

    # revoked? is relative to the clock, and travel puts revoked_at ahead of
    # the restored one — the durable fact is that it was stamped at all.
    refute_nil token.reload.revoked_at, "an expired session left a live credential behind"
  end

  # CookieStore means reset_session invalidates nothing the client already
  # holds: B signing in on the same workstation used to leave A's saved cookie
  # working, and audited as B.
  test "a different clinician signing in invalidates the previous session" do
    sign_in
    a_token = session_token
    a_cookies = cookies.to_hash

    sign_in("testprovider", "test123") # a different human, same workstation
    assert a_token.reload.revoked?, "the previous clinician's credential is still live"

    reset!
    a_cookies.each { |name, value| cookies[name] = value }
    get "/lakeraven-ehr/patients/1"
    assert_response :unauthorized
  end

  test "a broker outage revokes the token the session was carrying" do
    sign_in
    token = session_token

    down = Object.new
    def down.authenticate(**) = raise(RpmsRpc::Client::ConnectionError, "broker down")
    with_singleton(Lakeraven::EHR::AuthenticationService, :new, ->(*) { down }) { sign_in }

    assert token.reload.revoked?
  end

  # -- (c): a session-derived token must not authorize a cross-site write --

  # ActionController::API has no CSRF protection, and this PR is what gives
  # session-derived tokens write scopes. Reproduced with no Authorization
  # header, no CSRF token and a hostile Origin.
  test "a session-derived token cannot drive a state-changing API request" do
    sign_in

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" },
      headers: { "Origin" => "https://evil.example" }

    assert_response :unauthorized
  end

  test "a session-derived token still authorizes reads" do
    sign_in

    get "/lakeraven-ehr/Patient", params: { _id: "1" }
    assert_response :ok
  end

  # -- M: the C-CDA author must not be caller-supplied --------------------

  test "the C-CDA author cannot be forged through a request parameter" do
    setup_header_auth(scopes: "system/*.read system/*.write")

    post "/lakeraven-ehr/transitions_of_care",
      params: { patient_dfn: "1", author_name: "FORGED,AUTHOR", author_npi: "9999999999" },
      headers: @headers

    assert_response :created
    refute_includes response.body, "FORGED,AUTHOR"
    refute_includes response.body, "9999999999"
  end

  # -- M2: state the SHIPPED Part 2 position, and assert it ---------------

  # The previous version of this test iterated an empty collection and
  # asserted nothing. The uncomfortable fact it should have been pinning is
  # that the most widely held key in an RPMS site grants the Part 2 content
  # while the behavioural-health keys grant nothing at all.
  test "the chart key grants Part 2-bearing resource types and the BH keys grant nothing" do
    chart = Lakeraven::EHR::SessionScopePolicy.scopes_for(security_keys: [ :cprs_gui_chart ])
    bh = Lakeraven::EHR::SessionScopePolicy.scopes_for(security_keys: [ :bh_provider, :bh_supervisor ])

    assert_includes chart, "user/Observation.read", "PHQ-9 item 9 rides on Observation"
    assert_includes chart, "user/Condition.read",   "substance-use diagnoses ride on Condition"
    assert_empty bh, "the BH keys grant nothing today — see #494"
    assert_empty Lakeraven::EHR::SessionScopePolicy::BEHAVIORAL_HEALTH_TYPES
  end

  test "the dental keys do not grant global Condition write" do
    dental = Lakeraven::EHR::SessionScopePolicy.scopes_for(
      security_keys: [ :dental_provider, :dental_supervisor ]
    )

    refute_includes dental, "user/Condition.write"
    refute_includes dental, "user/Condition.read"
  end

  private

  # Minitest 6 dropped Object#stub; swap a singleton method and put it back.
  def with_singleton(target, name, impl)
    had = target.singleton_class.method_defined?(name) || target.singleton_class.private_method_defined?(name)
    original = target.method(name) if had
    target.define_singleton_method(name, &impl)
    yield
  ensure
    target.singleton_class.send(:remove_method, name)
    target.define_singleton_method(name, original) if original && !target.respond_to?(name)
  end

  # An export belonging to someone else, with real PHI in the payload.
  # Ownership is the subject here, not export generation.
  def seed_victim_export(owner: "another-client-uid")
    export = Lakeraven::EHR::BulkExport.new(
      id: "victim-export", export_type: "patient", status: "completed",
      request_url: "https://example.test/exports", output_format: "application/fhir+ndjson",
      client_id: owner
    )
    export.output_files = [
      { "file_name" => "PatientNdjson", "type" => "Patient", "count" => 1,
        "content" => '{"resourceType":"Patient","ssn":"111-11-1111","name":"Anderson,Alice"}' }
    ]
    Lakeraven::EHR::ExportsController.store["victim-export"] = export
  end

  def seed_provenance
    Lakeraven::EHR::ProvenanceStore.instance.add(
      Lakeraven::EHR::Provenance.new(
        target_type: "Patient", target_id: "rpms-1", activity: "CREATE",
        agent_who_id: "304", agent_who_type: "Practitioner", recorded: Time.current
      )
    )
  end

  def setup_header_auth(scopes:, resource_owner_id: nil)
    app = Doorkeeper::Application.create!(
      name: "hdr-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: scopes, expires_in: 3600, resource_owner_id: resource_owner_id
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def setup_read_only_header_auth
    setup_header_auth(scopes: "system/*.read")
  end

  def setup_patient_bound_auth(dfn:, scopes: "patient/*.read")
    setup_header_auth(scopes: scopes, resource_owner_id: dfn)
  end
end
