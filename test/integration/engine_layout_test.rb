# frozen_string_literal: true

require "test_helper"

# Every engine page shares one header: the product name, and once signed in,
# who the session belongs to and a way to end it. On a shared clinic
# workstation the next person at the keyboard has to be able to see whose
# session is open and close it.
class EngineLayoutTest < ActionDispatch::IntegrationTest
  test "a signed-in page names the user and offers sign out" do
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_name: "MANAGER,SYSTEM" }
    get "/lakeraven-ehr/dashboard"
    assert_response :success

    assert_select "header", text: /Lakeraven EHR/
    assert_select "header", text: /Signed in as\s+MANAGER,SYSTEM/
    assert_select "header form[action='/lakeraven-ehr/logout'] button", text: "Sign out"
  end

  test "the sign-in page offers no sign out" do
    get "/lakeraven-ehr/login"
    assert_response :success

    assert_select "header", text: /Lakeraven EHR/
    assert_select "header button", text: "Sign out", count: 0
  end
end
