# frozen_string_literal: true

require "test_helper"
require "securerandom"

# Live (rpms-ux S-REG-23, S-REG-31.1): the front desk registers a patient with
# the minimum and the registration lists what AG says is still missing, by
# section; recording an item takes it off the list. It WRITES patients, so it
# runs only against a throwaway container and only when asked twice:
# LIVE_RPMS=1 and LIVE_RPMS_WRITES=1. Never point it at a shared stack.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9110 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_missing_items_test.rb
class LiveRegistrationMissingItemsTest < ActionDispatch::IntegrationTest
  include RegistrationFormHelper

  # CLASSIFICATION/BENEFICIARY (#9999999.25) INDIAN/ALASKA NATIVE, entry 2 of
  # the IHS standard table.
  INDIAN_ALASKA_NATIVE = 2

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PREG123", password: "PREG123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  def picked(kind)
    search = kind == :tribe ? { tribe_search: "A" } : { community_search: "WAPANUCKA" }
    get "/lakeraven-ehr/registration/patients/new", params: search
    css_select("input[name='registration[#{kind}_ien]']").first["value"]
  end

  def register_minimum
    letters = Array.new(6) { ("A".."Z").to_a.sample }.join
    submit_registration(name: "LIVETEST,#{letters}", sex: "F", dob: Date.new(1960 + rand(30), 1 + rand(12), 1 + rand(28)).iso8601,
                        ssn: "", no_ssn_reason: "N", tribe_ien: picked(:tribe), community_ien: picked(:community))
    assert_response :redirect
    response.location[%r{/registration/patients/(\d+)\z}, 1].to_i
  end

  test "S-REG-23.1, S-REG-23.2 and S-REG-31.1 a new patient's missing items are listed by section, and a recorded one goes" do
    dfn = register_minimum
    get "/lakeraven-ehr/registration/patients/#{dfn}"

    assert_response :ok
    assert_select "#missing-items-counts [data-count='errors']", text: /\A[1-9]\d*\z/
    assert_select "#missing-items-counts [data-count='warnings']", text: /\A[1-9]\d*\z/
    assert_select "#missing-items h3[data-section='eligibility-and-tribe']"
    assert_select "#missing-items li[data-check='807'][data-kind='error']", text: /missing BENEFICIARY/
    assert_select "#missing-items li[data-check='40'][data-kind='warning']", text: /Homeless/
    errors_before = css_select("#missing-items-counts [data-count='errors']").first.text.to_i

    # Record the beneficiary class through AG's own update, the path the
    # registration's eligibility section files through.
    updated = RpmsRpc::Patient.update(dfn, classification: INDIAN_ALASKA_NATIVE)
    assert updated && updated[:success], "the classification was not filed: #{updated.inspect}"

    get "/lakeraven-ehr/registration/patients/#{dfn}"
    assert_select "#missing-items li[data-check='807']", count: 0
    assert_select "#missing-items-counts [data-count='errors']", text: (errors_before - 1).to_s
  end
end
