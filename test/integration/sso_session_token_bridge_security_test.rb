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

  # -- Copilot PRRT_kwDOR8fnY86gjRWf: a non-Bearer header must not short-
  #    circuit the session fallback on opt-in surfaces --------------------

  # A present-but-non-Bearer Authorization header (a proxy-injected `Basic`,
  # say) is "no bearer token found", not "a header was supplied so refuse":
  # on the HTML chart (an opt-in surface) a valid session must still authorize.
  test "a non-Bearer header does not block the session on the HTML chart" do
    sign_in

    get "/lakeraven-ehr/patients/1",
      headers: { "Authorization" => "Basic #{Base64.strict_encode64('proxy:secret')}" }

    assert_response :ok
    assert_includes response.body, "Anderson"
  end

  # ...but option 3 holds: the FHIR API never opts into the session, so a
  # non-Bearer header there still refuses (no fallthrough to session).
  test "a non-Bearer header on the FHIR API still refuses" do
    sign_in

    get "/lakeraven-ehr/Patient", params: { _id: "1" },
      headers: { "Authorization" => "Basic #{Base64.strict_encode64('proxy:secret')}" }

    assert_response :unauthorized
  end

  # -- Copilot PRRT_kwDOR8fnY86gjRXD: the browser SSO application create must
  #    be race-safe. The unique index is on `uid`, not `name`, so
  #    find_or_create_by!(name:) lets concurrent first-logins mint duplicate
  #    apps. Fixed uid ⇒ the DB catches the race. -------------------------

  test "the browser SSO application has a fixed uid so concurrent creates collide on the index" do
    sign_in

    apps = Doorkeeper::Application.where(name: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_NAME)
    assert_equal 1, apps.count
    assert_equal Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_UID, apps.first.uid
  end

  test "the browser SSO application create rescues the uid race and reuses the winner" do
    controller = Lakeraven::EHR::SessionsController.new
    winner = controller.send(:browser_sso_application) # creates it with the fixed uid

    # A caller that lost the find-by-name race and tries to create the same uid
    # hits the unique index and falls back to the winner — no duplicate.
    loser = controller.send(:create_browser_sso_application)

    assert_equal winner.id, loser.id
    assert_equal 1,
      Doorkeeper::Application.where(name: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_NAME).count
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

  test "a browser session cannot create a bulk export at all" do
    sign_in

    post "/lakeraven-ehr/exports", params: { export_type: "patient" }
    # Refused one step earlier than when this was written: a session-derived
    # token may not drive ANY state-changing API request (round 3, finding c),
    # so it never reaches the scope check that used to refuse it.
    assert_response :unauthorized
  end

  # P0: this branch must pass the merged-alone test. A `system/*.read` token
  # could POST /exports and bulk-export a record — authorize_fhir_write_scope!
  # existed but was invoked only on Patient#create. #501 supersedes this with
  # discloses_clinical_data + compartment binding; this gate exists so #486 is
  # safe without #501, in either landing order.
  test "a read-only header token cannot create a bulk export" do
    app = Doorkeeper::Application.create!(
      name: "ro-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: "system/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/*.read", expires_in: 3600
    )

    post "/lakeraven-ehr/exports", params: { export_type: "patient" },
      headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }

    assert_response :forbidden
  end

  test "a write-scoped header token can still create a bulk export" do
    app = Doorkeeper::Application.create!(
      name: "rw-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: "system/*.read system/*.write", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/*.read system/*.write", expires_in: 3600
    )

    post "/lakeraven-ehr/exports", params: { export_type: "patient" },
      headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }

    assert_response :accepted
  end

  # -- the browser/system discriminator must not hang on a display string ---

  test "a session token is marked intrinsically, not by its application name" do
    sign_in

    assert session_token.browser_session, "the mint did not stamp the token"
  end

  # The hazard this closes: a browser token that stops being recognised stops
  # being BOUND, and becomes replayable from an Authorization header.
  test "renaming the SSO application does not unbind a live session token" do
    sign_in
    token = session_token
    plaintext = token.plaintext_token || token.token
    Doorkeeper::Application.find_by(name: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_NAME)
      &.update!(name: "Renamed By An Admin")

    reset!
    get "/lakeraven-ehr/patients/1", headers: { "Authorization" => "Bearer #{plaintext}" }

    assert_response :unauthorized
  end

  # F3: a legacy browser token (browser_session=false, minted before the flag
  # migration) demotes to the name fallback, so an application rename would let
  # it replay from an Authorization header for its remaining lifetime. The
  # migration REVOKES such tokens rather than backfilling the flag; a revoked
  # token cannot be replayed no matter how it is later classified.
  test "the flag migration revokes legacy browser-SSO tokens" do
    require Lakeraven::EHR::Engine.root.join(
      "db", "migrate", "20260915000000_add_browser_session_to_oauth_access_tokens"
    ).to_s

    app = Doorkeeper::Application.create!(
      name: Lakeraven::EHR::SessionsController::BROWSER_SSO_APP_NAME,
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob", scopes: "user/*.read", confidential: true
    )
    legacy = Doorkeeper::AccessToken.create!(
      application: app, scopes: "user/*.read", expires_in: 12.hours.to_i,
      resource_owner_id: 304
    )
    legacy.update_columns(browser_session: false, revoked_at: nil)

    AddBrowserSessionToOauthAccessTokens.revoke_legacy_browser_tokens!(
      ActiveRecord::Base.connection
    )

    assert legacy.reload.revoked?, "a legacy browser token survived the migration"
  end

  # R2-1: the revoke must not key on the mutable name it was chosen to escape.
  # The round-2 gate reproduced a pre-flag token under an ALREADY-RENAMED
  # application surviving a name-keyed revoke and replaying from a header for
  # a 200. The revoke matches by shape as well — resource owner present, no
  # patient/ scope — which every browser token has regardless of what its
  # application is called.
  test "the revoke catches a legacy token whose application was already renamed" do
    require Lakeraven::EHR::Engine.root.join(
      "db", "migrate", "20260915000000_add_browser_session_to_oauth_access_tokens"
    ).to_s

    app = Doorkeeper::Application.create!(
      name: "Renamed Before Migration", redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "user/*.read", confidential: true
    )
    legacy = Doorkeeper::AccessToken.create!(
      application: app, scopes: "user/*.read", expires_in: 12.hours.to_i,
      resource_owner_id: 304
    )
    legacy.update_columns(browser_session: false, revoked_at: nil)
    raw = legacy.plaintext_token || legacy.token

    AddBrowserSessionToOauthAccessTokens.revoke_legacy_browser_tokens!(
      ActiveRecord::Base.connection
    )

    assert legacy.reload.revoked?,
      "a legacy browser token of a renamed application survived the revoke"
    get "/lakeraven-ehr/Patient", params: { _id: "1" },
      headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :unauthorized
  end

  # The other half of R2-1's bar: over-breadth must not log integrations out.
  # System/backend tokens have no resource owner and survive the revoke.
  test "the revoke does not touch system tokens" do
    require Lakeraven::EHR::Engine.root.join(
      "db", "migrate", "20260915000000_add_browser_session_to_oauth_access_tokens"
    ).to_s

    sys_app = Doorkeeper::Application.create!(
      name: "backend-integration", redirect_uri: "https://example.test/cb",
      scopes: "system/*.read", confidential: true
    )
    sys_token = Doorkeeper::AccessToken.create!(
      application: sys_app, scopes: "system/*.read", expires_in: 3600
    )

    AddBrowserSessionToOauthAccessTokens.revoke_legacy_browser_tokens!(
      ActiveRecord::Base.connection
    )

    refute sys_token.reload.revoked?, "the migration logged a backend integration out"
    get "/lakeraven-ehr/Patient", params: { _id: "1" },
      headers: { "Authorization" => "Bearer #{sys_token.plaintext_token || sys_token.token}" }
    assert_response :ok
  end

  test "a header token is not mistaken for a browser credential" do
    app = Doorkeeper::Application.create!(
      name: "system-client", redirect_uri: "https://example.test/cb",
      scopes: "system/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/*.read", expires_in: 3600
    )

    get "/lakeraven-ehr/Patient", params: { _id: "1" },
      headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }

    assert_response :ok
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
  # The whole sign-on sequence runs under the broker wire lock.
  #
  # Behavioral, against the REAL gem lock (rpms-rpc 0.3.0 provides
  # RpmsRpc.synchronize_wire and its MockClient models it): two concurrent
  # sign-ons must not interleave on the process-global broker client. If the
  # sequence — authenticate, user_info, ORWU USERKEYS — is one locked unit,
  # thread 2 cannot enter its own `authenticate` until thread 1 releases, so
  # the in-flight count never exceeds one.
  #
  # Spies on RpmsRpc::Authentication.authenticate, which is safe to restore:
  # it is exposed via `extend self`, so removing a singleton override reveals
  # the gem's instance method again. (The old version of this test stubbed
  # RpmsRpc.synchronize_wire and remove_method'd it in ensure — which, now
  # that the gem defines it directly on the singleton, DELETED the real method
  # for the rest of the process and cascaded 11 failures. That is the
  # blind-mock archetype: it never exercised the real lock.)
  test "concurrent sign-ons cannot interleave on the shared broker client" do
    in_flight = 0
    max_seen = 0
    monitor = Monitor.new

    original = RpmsRpc::Authentication.method(:authenticate)
    RpmsRpc::Authentication.define_singleton_method(:authenticate) do |**kwargs|
      monitor.synchronize { in_flight += 1; max_seen = [ max_seen, in_flight ].max }
      sleep 0.05 # widen the window; this runs INSIDE synchronize_wire
      monitor.synchronize { in_flight -= 1 }
      original.call(**kwargs)
    end

    threads = 2.times.map do
      Thread.new do
        Lakeraven::EHR::AuthenticationService.new.authenticate(
          access_code: "lindarodriguez", verify_code: "test123"
        )
      end
    end
    threads.each(&:join)

    assert_equal 1, max_seen,
      "two sign-ons ran through the shared broker client at once"
  ensure
    RpmsRpc::Authentication.singleton_class.send(:remove_method, :authenticate)
  end

  # The app-level process-local fallback still serializes when a gem WITHOUT
  # RpmsRpc.synchronize_wire is in play (an older gem, or a future regression).
  # 0.3.0 always provides the lock, so this forces the fallback branch by
  # making RpmsRpc report the method absent, and asserts the BROKER_WIRE_MUTEX
  # still prevents interleave.
  test "sign-on falls back to a process-local lock when the gem lacks one" do
    in_flight = 0
    max_seen = 0
    monitor = Monitor.new

    real_respond = RpmsRpc.method(:respond_to?)
    RpmsRpc.singleton_class.send(:define_method, :respond_to?) do |name, *args|
      next false if name.to_sym == :synchronize_wire

      real_respond.call(name, *args)
    end

    original = RpmsRpc::Authentication.method(:authenticate)
    RpmsRpc::Authentication.define_singleton_method(:authenticate) do |**kwargs|
      monitor.synchronize { in_flight += 1; max_seen = [ max_seen, in_flight ].max }
      sleep 0.05
      monitor.synchronize { in_flight -= 1 }
      original.call(**kwargs)
    end

    threads = 2.times.map do
      Thread.new do
        Lakeraven::EHR::AuthenticationService.new.authenticate(
          access_code: "lindarodriguez", verify_code: "test123"
        )
      end
    end
    threads.each(&:join)

    assert_equal 1, max_seen,
      "the process-local fallback let two sign-ons interleave"
  ensure
    RpmsRpc::Authentication.singleton_class.send(:remove_method, :authenticate)
    RpmsRpc.singleton_class.send(:remove_method, :respond_to?)
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

  test "a broker that refuses the sign-on RPCs renders a sign-in failure rather than an exception" do
    [ RpmsRpc::Client::RpcError.new("4 Access denied for remote procedure: XUS AV CODE"),
      RpmsRpc::Client::AuthenticationError.new("CIA sign-on rejected") ].each do |error|
      refusing = Object.new
      refusing.define_singleton_method(:authenticate) { |**| raise error }

      with_singleton(Lakeraven::EHR::AuthenticationService, :new, ->(*) { refusing }) do
        sign_in
        assert_response :service_unavailable, error.class.name
        assert_nil session[:duz]
      end
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

  # The session token reads the HTML CHART (its only surface), not the FHIR API
  # (bearer-only). The FHIR fallback was overreach a cross-site Lax GET could
  # ride (#512 F1 / #525).
  test "a session-derived token reads the HTML chart but not the FHIR API" do
    sign_in

    get "/lakeraven-ehr/patients/1" # HTML chart
    assert_response :ok

    get "/lakeraven-ehr/Patient", params: { _id: "1" } # FHIR API — bearer only
    assert_response :unauthorized
  end

  # -- M: the C-CDA author must not be caller-supplied --------------------

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

  def setup_patient_bound_auth(dfn:, scopes: "patient/*.read")
    setup_header_auth(scopes: scopes, resource_owner_id: dfn)
  end
end
