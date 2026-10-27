# frozen_string_literal: true

require "test_helper"

# Live (rpms-ux S-REG-01): the front-desk persona signs in through the login
# form, so its session carries the keys RPMS reports, and finds a patient the
# build's demo site has. Skipped unless LIVE_RPMS=1 (see test_helper.rb), e.g.
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9110 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_registration_find_patient_test.rb
class LiveRegistrationFindPatientTest < ActionDispatch::IntegrationTest
  setup do
    skip "live: set LIVE_RPMS=1 and a broker" unless defined?(LIVE_RPMS) && LIVE_RPMS
    Lakeraven::EHR::LoginThrottle.reset!
  end

  # One process holds one broker identity (rpms-rpc#234).
  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS }

  test "the front desk finds MOUSE,MICKEY M with health record number 1001, and opens the registration" do
    post "/lakeraven-ehr/login", params: { username: "PREG123", password: "PREG123!!" }
    assert_response :redirect
    assert_includes session[:security_keys], "registration_menu"

    get "/lakeraven-ehr/registration/patients", params: { q: "MOUSE", dob: "1910-02-14" }

    assert_response :ok
    assert_select "#matches tr[data-dfn='3'] td", text: "1001"
    assert_select "#matches tr[data-dfn='3'] td[data-status='active']"

    get "/lakeraven-ehr/registration/patients", params: { q: "ZZZNOBODY" }
    assert_select "#no-match"

    get "/lakeraven-ehr/registration/patients/3"
    assert_response :ok
    assert_select "h1", text: "MOUSE,MICKEY M"

    get "/lakeraven-ehr/registration/patients/987654"
    assert_response :not_found
  end

  test "the physician, who holds no registration key, is refused the front desk's search" do
    post "/lakeraven-ehr/login", params: { username: "PMD123", password: "PMD123!!" }
    assert_response :redirect

    get "/lakeraven-ehr/registration/patients", params: { q: "MOUSE" }
    assert_response :forbidden
  end
end
