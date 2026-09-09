# frozen_string_literal: true

require "test_helper"

# The browser SSO bridge: a clinician signs in with RPMS access/verify codes,
# SessionsController validates them (AuthenticationService -> RpmsRpc signon,
# mocked here via the seeded testprovider user), mints a SMART user-scoped
# token, and stashes it in the session. SmartAuthentication then accepts that
# session token when no Authorization header is present — so the human chart
# runs on real SMART auth without the dev bypass, and without a Bearer header
# a browser can't send.
class SsoSessionTokenBridgeTest < ActionDispatch::IntegrationTest
  test "form sign-on mints a session token that authorizes the chart with no Bearer header" do
    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test123" }
    assert_response :redirect

    # No Authorization header — authorization must come from the session token
    # the sign-on minted. Patient 1 (Anderson,Alice) is seeded in test_helper.
    get "/lakeraven-ehr/patients/1"
    assert_response :ok
    assert_includes response.body, "Anderson"
  end

  test "failed sign-on establishes no session, so the chart stays unauthorized" do
    # Empty verify is rejected deterministically by AuthenticationService.
    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "" }
    assert_response :unprocessable_entity

    get "/lakeraven-ehr/patients/1"
    assert_response :unauthorized
  end

  test "sign-out clears the session token" do
    post "/lakeraven-ehr/login", params: { username: "testprovider", password: "test123" }
    get "/lakeraven-ehr/patients/1"
    assert_response :ok

    delete "/lakeraven-ehr/logout"
    get "/lakeraven-ehr/patients/1"
    assert_response :unauthorized
  end
end
