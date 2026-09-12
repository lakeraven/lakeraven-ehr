# frozen_string_literal: true

require "test_helper"

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

  test "behavioural-health scopes require a behavioural-health key" do
    sign_in # 304 holds prc_supervisor + cprs_gui_chart, no BH key

    scopes = session_token.scopes.to_a
    Lakeraven::EHR::SessionScopePolicy::BEHAVIORAL_HEALTH_TYPES.each do |type|
      refute_includes scopes, "user/#{type}.read"
      refute_includes scopes, "user/#{type}.write"
    end
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
    assert_response :forbidden
  end

  # -- B3: sign-out must revoke ---------------------------------------------

  test "sign-out revokes the token server-side, not just the cookie" do
    sign_in
    token = session_token

    delete "/lakeraven-ehr/logout"

    assert token.reload.revoked?, "the token outlived the session that minted it"
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

  def setup_patient_bound_auth(dfn:)
    setup_header_auth(scopes: "patient/*.read", resource_owner_id: dfn)
  end
end
