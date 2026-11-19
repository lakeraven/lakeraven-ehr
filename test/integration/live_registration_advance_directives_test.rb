# frozen_string_literal: true

require "test_helper"
require "rpms_rpc/api/ddr_fileman"

# Live (rpms-ux S-REG-17): the front-desk persona records, changes and removes
# a patient's advance directive on a real RPMS, FileMan is read back, and the
# registration warning AG*7.1*17 adds while none is on file (AG error 55)
# clears from the patient's page. It WRITES, so it runs only against a
# throwaway container and only when asked twice: LIVE_RPMS=1 and LIVE_RPMS_WRITES=1.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9143 \
#   LIVE_RPMS_ACCESS=PREG123 LIVE_RPMS_VERIFY='PREG123!!' \
#   bin/rails test test/integration/live_registration_advance_directives_test.rb
class LiveRegistrationAdvanceDirectivesTest < ActionDispatch::IntegrationTest
  DFN = 990_047 # a synthetic seed patient no other live test writes to
  BASE = "/lakeraven-ehr/registration/patients/#{DFN}".freeze
  WARNING = "55" # Advance Directives missing (AG*7.1*17)

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    clear
    sign_in
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"

    clear
  end

  def sign_in
    post "/lakeraven-ehr/login", params: { username: ENV.fetch("LIVE_RPMS_ACCESS"), password: ENV.fetch("LIVE_RPMS_VERIFY") }
  end

  def clear
    LiveRpmsSession.sign_on!
    RpmsRpc::Registration.advance_directives(DFN).each { |row| RpmsRpc::Registration.remove_advance_directive(DFN, row[:ien]) }
  end

  # FileMan's own read of the patient's DATE OF ENTRY multiple (9000040.11):
  # [[ien, date, answer, type, reason]], internal values.
  def fileman
    LiveRpmsSession.sign_on!
    listed = RpmsRpc.client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.lister(file: "9000040.11", iens: ",#{DFN},", fields: "@;.01I;.02I;.03I;.04", flags: "IP")
    end
    sign_in
    listed[:entries].map { |entry| [ entry[:ien].to_i, *entry[:pieces].first(4).map(&:to_s) ] }
  end

  def warned?
    get BASE
    assert_response :success
    css_select("#missing-items [data-check='#{WARNING}']").any?
  end

  test "S-REG-17.2 and 17.8 no directive with a reason is on file, and the intake warning clears" do
    assert warned?, "AG warns while the patient has no advance directive on file"

    post "#{BASE}/advance_directives",
         params: { advance_directive: { entered_on: "2026-11-16", directive: "N", reason: "PATIENT HAS NONE" } }
    assert_response :redirect, flash[:alert].to_s

    ien, date, answer, type, reason = fileman.sole
    assert_equal [ "3261116", "N", "", "PATIENT HAS NONE" ], [ date, answer, type, reason ]
    refute warned?, "the warning is gone once an answer is on file"
    assert_select "#advance-directives-section [data-field='advance_directive']", text: /No \(PATIENT HAS NONE\)/

    post "#{BASE}/advance_directives/#{ien}/remove"
    assert_response :redirect
    assert_empty fileman
  end

  test "S-REG-17.1 and 17.6 a directive is filed with its type, then changed in place" do
    get "#{BASE}/advance_directives"
    type = css_select("#advance_directive_type_ien option").map { |option| option["value"] }.reject(&:empty?).first
    assert type, "the demo file has advance-directive types"

    post "#{BASE}/advance_directives",
         params: { advance_directive: { entered_on: "2026-11-02", directive: "Y", type_ien: type } }
    assert_response :redirect, flash[:alert].to_s
    ien, *filed = fileman.sole
    assert_equal [ "3261102", "Y", type, "" ], filed

    post "#{BASE}/advance_directives/#{ien}",
         params: { advance_directive: { entered_on: "2026-11-02", directive: "N", type_ien: type, reason: "REVOKED BY PATIENT" } }
    assert_response :redirect, flash[:alert].to_s
    assert_equal [ [ ien, "3261102", "N", "", "REVOKED BY PATIENT" ] ], fileman
  end

  test "S-REG-17.3 the same type on the same date is refused, and one entry stays on file" do
    get "#{BASE}/advance_directives"
    type = css_select("#advance_directive_type_ien option").map { |option| option["value"] }.reject(&:empty?).first
    entry = { entered_on: "2026-11-03", directive: "Y", type_ien: type }

    post "#{BASE}/advance_directives", params: { advance_directive: entry }
    assert_response :redirect, flash[:alert].to_s
    post "#{BASE}/advance_directives", params: { advance_directive: entry }

    assert_response :unprocessable_content
    assert_select "#advance-directives-alert", text: /already on file for that date/
    assert_equal 1, fileman.size
  end
end
