# frozen_string_literal: true

require "test_helper"

# Live (#973): the registration persona, who holds AGZMENU, opens the
# registration record of DEMO,PATIENT ONE, the pinned build's patient with
# Medicare on file. AG's edit checks for that patient name windows the page
# does not map (Medicare Eligibility), sent as ASCII-8BIT; the page answered
# 500 on them. It only reads, so LIVE_RPMS=1 alone runs it:
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9100 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_record_with_coverage_test.rb
class LiveRegistrationRecordWithCoverageTest < ActionDispatch::IntegrationTest
  DEMO_PATIENT_ONE = 4

  setup do
    skip "live: set LIVE_RPMS=1 against an RPMS container" unless defined?(LIVE_RPMS) && LIVE_RPMS
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PREG123", password: "PREG123!!" }
  end

  test "a clerk holding AGZMENU opens the registration record of a patient with coverage" do
    get "/lakeraven-ehr/registration/patients/#{DEMO_PATIENT_ONE}"

    assert_response :ok
    assert_select "#missing-items h3[data-section='medicare-eligibility']", text: "Medicare Eligibility"
  end
end
