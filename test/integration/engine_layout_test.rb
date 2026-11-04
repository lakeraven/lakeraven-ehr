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

  test "the header links to the screens the user's keys open, and only those" do
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_name: "SCHED,USER", security_keys: [ "scheduling_user" ] }
    get "/lakeraven-ehr/dashboard"

    assert_select "nav[aria-label='Main'] a[href='/lakeraven-ehr/scheduling']", text: "Scheduling"
    assert_select "nav[aria-label='Main'] a", text: "Registration", count: 0
  end

  test "a user with no scheduling or registration key sees neither link" do
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_name: "PROVIDER,TEST", security_keys: [ "orders_sign" ] }
    get "/lakeraven-ehr/dashboard"

    assert_select "nav[aria-label='Main'] a", count: 0
  end

  test "a refused screen says why and leads back, not a blank page" do
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_name: "PROVIDER,TEST", security_keys: [ "orders_sign" ] }
    get "/lakeraven-ehr/scheduling"

    assert_response :forbidden
    assert_select "h1", text: "You don't have access to this screen"
    assert_select "main a[href='/lakeraven-ehr/dashboard']"
  end

  # Which name belongs in the chrome is undecided (docs/adr, "product name in
  # the chrome"), so it is one setting: the header and every <title> follow it.
  test "the header and the page title take the product name from one setting" do
    Lakeraven::EHR.configuration.product_name = "Front desk"
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_name: "REG,USER", security_keys: [ "registration_user" ] }
    get "/lakeraven-ehr/dashboard"

    assert_select "header a", text: "Front desk"
    assert_select "header", text: /Lakeraven/, count: 0
    assert_select "title", text: /\| Front desk\z/
  ensure
    Lakeraven::EHR.configuration.product_name = "Lakeraven EHR"
  end

  test "the sign-in page offers no sign out" do
    get "/lakeraven-ehr/login"
    assert_response :success

    assert_select "header", text: /Lakeraven EHR/
    assert_select "header button", text: "Sign out", count: 0
  end
end
