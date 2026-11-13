# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_registration_switches"

# Live (lakeraven-ehr#981): the registration screens show a section only when
# the signed-on division's RPMS registration switches ask for it,
# REGISTRATION PARAMETERS (#9009061) fields 1 to 8. Each test sets the
# switches through DDR FILER first, as a site manager's edit would leave
# them, and puts them back after. It WRITES, so it runs only against a
# throwaway container and only when asked twice: LIVE_RPMS=1 and
# LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=19180 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_site_switches_test.rb
class LiveRegistrationSiteSwitchesTest < ActionDispatch::IntegrationTest
  DFN = 990_009 # INDIA,QUINN, a synthetic seed patient
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze
  SWITCHES = %i[blood_quantum enrollment_number other_names medicaid private_insurance next_of_kin other_tribes].freeze

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"

    LiveRegistrationSwitches.put_back(@before)
    LiveRpmsSession.sign_on!
  end

  def sign_in
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  def switch_all(on)
    before = LiveRegistrationSwitches.set(SWITCHES.to_h { |switch| [ switch, on ] })
    @before ||= before
    sign_in
  end

  test "switches set to NO hide the identifiers, next of kin and coverage they ask for" do
    switch_all(false)

    get BASE
    assert_response :ok
    assert_select "#other-names-section", count: 0
    assert_select "#other-tribes-section [data-field='other_tribes']", count: 0
    assert_select "#contact-emergency"
    assert_select "#contact-next-of-kin", count: 0

    get "#{BASE}/eligibility/edit"
    assert_response :ok
    assert_select "input[name='eligibility[blood_quantum]']", count: 0
    assert_select "input[name='eligibility[enrollment_number]']", count: 0

    get "#{BASE}/coverage"
    assert_select "#add-medicare"
    assert_select "#add-medicaid", count: 0
    assert_select "#add-private", count: 0

    get "#{BASE}/other_names"
    assert_redirected_to BASE
  end

  test "switches set to YES show them" do
    switch_all(true)

    get BASE
    assert_response :ok
    assert_select "#other-names-section"
    assert_select "#other-tribes-section [data-field='other_tribes']"
    assert_select "#contact-next-of-kin"

    get "#{BASE}/eligibility/edit"
    assert_select "input[name='eligibility[blood_quantum]']"
    assert_select "input[name='eligibility[enrollment_number]']"

    get "#{BASE}/coverage"
    assert_select "#add-medicaid"
    assert_select "#add-private"
  end
end
