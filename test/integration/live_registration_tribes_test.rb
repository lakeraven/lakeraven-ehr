# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_registration_switches"
require "rpms_rpc/api/ddr_fileman"

# Live (rpms-ux S-REG-07.2, S-REG-07.3): the front-desk persona records a second
# tribe and an eligibility reason on a real RPMS, and FileMan is read back. It
# WRITES, so it runs only against a throwaway container and only when asked
# twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9143 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_tribes_test.rb
class LiveRegistrationTribesTest < ActionDispatch::IntegrationTest
  DFN = 990_013 # a synthetic seed patient
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze
  TRIBE = 5

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    # The demo division answers NO to these switches, which hide the section (#981).
    @registration_switches = LiveRegistrationSwitches.turn_on(:other_tribes)
    Lakeraven::EHR::LoginThrottle.reset!
    LiveRpmsSession.sign_on!
    assert RpmsRpc::Registration.update(DFN, eligibility_status: "D")[:success]
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"

    LiveRegistrationSwitches.put_back(@registration_switches)
    LiveRpmsSession.sign_on!
  end

  def fileman(file)
    LiveRpmsSession.sign_on!
    listed = RpmsRpc.client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.lister(file: file, iens: ",#{DFN},", fields: "@;.01I#{";.02" if file.end_with?('.43')}", flags: "IP")
    end
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
    listed[:entries].map { |entry| entry[:pieces] }
  end

  test "S-REG-07.2 a second tribe and its quantum are on file, and it can be removed" do
    post "#{BASE}/other_tribes", params: { other_tribe: { tribe_ien: TRIBE, quantum: "1/8" } }
    assert_response :redirect, flash[:alert].to_s

    assert_includes fileman("9000001.43"), [ TRIBE.to_s, "1/8" ]

    get "#{BASE}/other_tribes"
    entry = css_select("#other-tribes tr[data-other-tribe]").first["data-other-tribe"]
    post "#{BASE}/other_tribes/#{entry}/remove"
    assert_response :redirect
    refute_includes fileman("9000001.43"), [ TRIBE.to_s, "1/8" ]
  end

  test "S-REG-07.3 a reason of the patient's status is on file once, and it can be removed" do
    get "#{BASE}/eligibility_modifiers"
    reason = css_select("#modifier_ien option").map { |option| option["value"] }.reject(&:empty?).first
    assert reason, "the demo file has reasons for the status"

    post "#{BASE}/eligibility_modifiers", params: { modifier_ien: reason }
    assert_response :redirect, flash[:alert].to_s
    assert_includes fileman("9000001.03401"), [ reason ]

    post "#{BASE}/eligibility_modifiers", params: { modifier_ien: reason }
    assert_response :unprocessable_content
    assert_select "#eligibility-modifiers-alert", text: /already recorded/
    assert_equal 1, fileman("9000001.03401").count([ reason ])

    post "#{BASE}/eligibility_modifiers/#{reason}/remove"
    assert_response :redirect
    refute_includes fileman("9000001.03401"), [ reason ]
  end
end
