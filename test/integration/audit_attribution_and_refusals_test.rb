# frozen_string_literal: true

require "test_helper"

# WHO the audit row names, and WHEN a refusal is written.
#
# Two contracts, both found broken by the adversarial gate on #507:
#
#   * Attribution (S2): the session DUZ may attribute a request ONLY when the
#     request was authenticated BY that session. A bearer-token request
#     arriving from a browser that also carries a session must NOT be filed
#     under the session's human — that is a misattribution, worse than the
#     unattributed row it replaced. Token + session on one request is an
#     auditable anomaly, recorded as such, never a precedence pick.
#
#   * Refusal coverage (S3): an anonymous probe of ANY browser page leaves a
#     refusal row. The base `require_authentication` every WebController page
#     inherits is the method that has to write it — a fix applied to one
#     controller's override leaves every other page silent.
class AuditAttributionAndRefusalsTest < ActionDispatch::IntegrationTest
  setup { Lakeraven::EHR::AuditEvent.delete_all }

  # -- S2: the recorded actor must be the right human -----------------------

  # The gate's exact reproduction: a `system/*.read` backend token read
  # /patients/1 from a browser carrying a session for a signed-in clinician,
  # and the row named that clinician. The token authenticated the request;
  # the session did not.
  test "a token-authenticated read is not attributed to a bystanding browser session" do
    sign_in_browser_session # session[:duz] = "99999"
    setup_auth(scopes: "system/*.read system/Patient.read")

    get "/patients/1", headers: @headers
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "the chart read left no audit trail"
    refute_equal [ "Practitioner", "99999" ],
                 [ event.agent_who_type, event.agent_who_identifier ],
                 "a token-authenticated read was filed under the browser session's human"
    assert_equal "Application", event.agent_who_type
    assert_equal @application.uid, event.agent_who_identifier
  end

  test "token and session on one request is recorded as an identity anomaly" do
    sign_in_browser_session
    setup_auth(scopes: "system/*.read system/Patient.read")

    get "/patients/1", headers: @headers

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_match(/identity anomaly/i, event.outcome_desc.to_s,
                 "a token/session disagreement was silently resolved instead of recorded")
  end

  # F1 (round-2 gate, both seats): the sibling of S2. "No token OBJECT" is
  # not "the session authenticated this" — a FHIR surface is NEVER
  # session-authenticated, so its refusals must not name the browser's
  # bystanding human. With SameSite=Lax cookies, any cross-site top-level
  # GET mints these rows against an innocent signed-in clinician.
  test "a tokenless FHIR refusal is not attributed to a bystanding browser session" do
    sign_in_browser_session # session[:duz] = "99999"

    get "/lakeraven-ehr/Patient/1" # no Authorization header at all
    assert_response :unauthorized

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "the tokenless refusal left no audit trail"
    refute_equal [ "Practitioner", "99999" ],
                 [ event.agent_who_type, event.agent_who_identifier ],
                 "a refusal the session did not make was filed under the session's human"
    assert_equal "Unknown", event.agent_who_type
    assert_match(/bystanding browser session/i, event.outcome_desc.to_s,
                 "the bystanding session was silently ignored instead of recorded as an anomaly")
  end

  test "a garbage bearer token with a bystanding session is not attributed to the session" do
    sign_in_browser_session

    get "/lakeraven-ehr/Patient/1", headers: { "Authorization" => "Bearer not-a-real-token" }
    assert_response :unauthorized

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "the garbage-token refusal left no audit trail"
    refute_equal "99999", event.agent_who_identifier,
                 "an unknown token string fell through to the bystanding session's human"
    assert_equal "Unknown", event.agent_who_type
  end

  # The #486 landmine, pinned (round-2 gate item 5): if a sibling branch ever
  # defines `current_duz` as "whatever is in the session", the token
  # mechanism must STILL win — a session-derived current_duz beating token
  # identity silently reopens S2. SessionShadowedApiController models
  # exactly that hazardous future implementation.
  test "a session-derived current_duz cannot beat token identity" do
    sign_in_browser_session
    setup_auth(scopes: "system/*.read")

    get "/session_shadowed_api/1", headers: @headers
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event
    refute_equal [ "Practitioner", "99999" ],
                 [ event.agent_who_type, event.agent_who_identifier ],
                 "a session-derived current_duz overrode the token that actually authenticated the request"
    assert_equal "Application", event.agent_who_type
    assert_equal @application.uid, event.agent_who_identifier
  end

  # The half that must KEEP working: a page authenticated by the session
  # itself is correctly filed under the session's human.
  test "a session-authenticated page is attributed to the session's human" do
    sign_in_browser_session

    get "/lakeraven-ehr/dashboard"
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "a session-authenticated page left no audit trail"
    assert_equal "Practitioner", event.agent_who_type
    assert_equal "99999", event.agent_who_identifier
  end

  # -- S3: refusals on EVERY browser page, not just the one that overrides --

  test "an anonymous probe of each browser page leaves a refusal row naming the reason" do
    {
      "/lakeraven-ehr/dashboard" => "engine page",
      "/staff" => "inheriting host page (staff)",
      "/worklists" => "inheriting host page (worklists)"
    }.each do |path, label|
      Lakeraven::EHR::AuditEvent.delete_all

      get path
      assert_response :redirect, "#{label} did not redirect an anonymous visitor"

      event = Lakeraven::EHR::AuditEvent.order(:id).last
      refute_nil event, "an anonymous probe of #{label} (#{path}) left no audit trail"
      refute_equal "0", event.outcome, "#{label} recorded an anonymous probe as a success"
      assert_match(/not signed in|sign.?in/i, event.outcome_desc.to_s,
                   "#{label} recorded a refusal with no reason")
      assert_equal "Unknown", event.agent_who_type
      assert_nil event.agent_who_identifier
    end
  end

  test "twenty anonymous probes leave twenty rows, not zero" do
    20.times { get "/lakeraven-ehr/dashboard" }

    assert_equal 20, Lakeraven::EHR::AuditEvent.count,
                 "anonymous probes of a browser page went unrecorded"
  end

  # -- outcome semantics: a successful redirect is not a serious failure ----

  # Without this, S3's fix would poison the refusals scope: every successful
  # browser redirect (a login, a form submit) would be filed as outcome "8",
  # and "we determined no" would be indistinguishable from "we said yes and
  # redirected".
  test "a successful sign-in redirect is recorded as a success, not a serious failure" do
    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test" }
    assert_response :redirect

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "signing in left no audit trail"
    assert_equal "0", event.outcome,
                 "a successful redirect was recorded as a failure"
  end

  test "a refusal redirect is recorded as a failure" do
    get "/lakeraven-ehr/dashboard"

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event
    assert_equal "4", event.outcome,
                 "a refusal redirect was not recorded as a determined refusal"
  end

  private

  def sign_in_browser_session
    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test" }
    assert_equal "99999", session[:duz], "the canned test sign-in did not establish a session"
  end

  def setup_auth(scopes:)
    @application = Doorkeeper::Application.create!(
      name: "client-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @application, scopes: scopes, expires_in: 3600
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end
end
