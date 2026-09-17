# frozen_string_literal: true

require "test_helper"

# The browser SSO bridge: a clinician signs in with RPMS access/verify codes,
# SessionsController validates them (AuthenticationService -> RpmsRpc signon,
# mocked here via the seeded users), mints a SMART token scoped by that
# clinician's security keys, and stashes it in the session. SmartAuthentication
# accepts that session token when no Authorization header is present — so the
# human chart runs on real SMART auth without the dev bypass, and without a
# Bearer header a browser can't send.
#
# Binding, scope derivation, revocation, throttling and audit identity are
# exercised in sso_session_token_bridge_security_test.rb.
class SsoSessionTokenBridgeTest < ActionDispatch::IntegrationTest
  # 304 RODRIGUEZ,LINDA holds OR CPRS GUI CHART, so she can open a chart.
  # 303 CLERK,TEST holds no security keys, so she cannot.
  KEYED_USER = { username: "lindarodriguez", password: "test123" }.freeze
  KEYLESS_USER = { username: "testclerk", password: "test123" }.freeze

  setup { Lakeraven::EHR::LoginThrottle.reset! }
  teardown { Lakeraven::EHR::LoginThrottle.reset! }

  test "form sign-on mints a session token that authorizes the chart with no Bearer header" do
    post "/lakeraven-ehr/login", params: KEYED_USER
    assert_response :redirect

    # No Authorization header — authorization must come from the session token
    # the sign-on minted. Patient 1 (Anderson,Alice) is seeded in test_helper.
    get "/lakeraven-ehr/patients/1"
    assert_response :ok
    assert_includes response.body, "Anderson"
  end

  test "sign-on records who signed in" do
    post "/lakeraven-ehr/login", params: KEYED_USER

    assert_equal "304", session[:duz]
    assert_equal "RODRIGUEZ,LINDA", session[:user_name]
  end

  # The previous version of this test posted an EMPTY password, which returns
  # from AuthenticationService's blank guard before any RPC is issued — it
  # proved the empty-string check and would have passed with authentication
  # stubbed to always succeed. This one sends a well-formed credential that
  # RPMS rejects, so the rejection has to come back from the broker.
  test "a credential RPMS rejects establishes no session" do
    post "/lakeraven-ehr/login", params: { username: "lindarodriguez", password: "wrongverify" }
    assert_response :unprocessable_entity

    assert_nil session[:duz]
    assert_nil session[:smart_token]

    get "/lakeraven-ehr/patients/1"
    assert_response :unauthorized
  end

  test "the rejection reaches RPMS rather than short-circuiting" do
    before = RpmsRpc.client.received_calls.length

    post "/lakeraven-ehr/login", params: { username: "lindarodriguez", password: "wrongverify" }

    issued = RpmsRpc.client.received_calls[before..].map { |c| c[:rpc] }
    assert_includes issued, "XUS AV CODE"
  end

  test "a clinician with no security keys signs in but is authorized for nothing" do
    post "/lakeraven-ehr/login", params: KEYLESS_USER
    assert_response :redirect
    assert_equal "303", session[:duz]

    get "/lakeraven-ehr/patients/1"
    assert_response :forbidden
  end

  test "sign-out ends the browser session" do
    post "/lakeraven-ehr/login", params: KEYED_USER
    get "/lakeraven-ehr/patients/1"
    assert_response :ok

    delete "/lakeraven-ehr/logout"
    get "/lakeraven-ehr/patients/1"
    assert_response :unauthorized
  end

  # The login POST is open in every environment now, so the forgery protection
  # that the test environment disables globally has to be exercised somewhere.
  test "a cross-site POST to the login route establishes no session" do
    with_forgery_protection do
      post "/lakeraven-ehr/login", params: KEYED_USER
    end

    assert_nil session[:duz], "a request with no authenticity token signed a clinician in"
  end

  private

  def with_forgery_protection
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
