# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-06): the scheduler persona books and checks in a walk-in
# on a real RPMS, and what RPMS then holds is read back from FileMan. It
# WRITES, so it runs only against a throwaway container and only when asked
# twice. It needs the clinic open now (a weekday inside DEMO IHS CLINIC's
# 08:00-17:00 blocks on the server's clock).
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_walk_in_test.rb
class LiveSchedulingWalkInTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "PSCH123", password: "PSCH123!!" }
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-06.1 the scheduler books MOUSE,MICKEY M as a walk-in at DEMO IHS CLINIC and checks them in, in one step" do
    clinic = clinic_path("DEMO IHS CLINIC")
    get clinic, params: { date: Date.today.iso8601 }
    walk_in = css_select("a#walk-in").first
    assert walk_in, "today's day view offers a walk-in"

    post "#{clinic}/walk_ins/find", params: { q: "MOUSE", provider_search: "PROFILE", walk_in: { at: Time.now.strftime("%Y-%m-%dT%H:%M") } }
    assert_select "#walk-in-form label[data-patient='3']"
    provider = css_select("#walk-in-form label[data-provider]").find { |l| l.text.upcase.include?("PROFILE,MD") }["data-provider"]

    now = Time.now
    post "#{clinic}/walk_ins", params: { walk_in: { patient_dfn: "3", at: now.strftime("%Y-%m-%dT%H:%M"), provider_ien: provider } }
    skip "the clinic is not open now on the server's clock" if response.status == 409
    assert_response :redirect, flash[:alert].to_s
    follow_redirect!
    assert_select "#notice", text: /Walk-in booked and checked in/

    slot = Time.new(now.year, now.month, now.day, now.hour, now.min - (now.min % 15))
    entry = clinic_appointments(clinic_ien("DEMO IHS CLINIC"), slot).find { |r| r[:patient] == "3" }
    assert entry, "#44.003 holds the walk-in at #{slot.strftime('%H:%M')}"
    pt = in_chart_context { RpmsRpc::DdrFileman.gets_entry(file: "2.98", iens: "#{fm(slot)},3,", fields: "3;9;9.5", flags: "IE") }
    assert_equal "4", pt[:fields]["9"][:internal], "#2.98 PURPOSE OF VISIT is unscheduled (a walk-in)"
    checked = in_chart_context { RpmsRpc::DdrFileman.gets_entry(file: "44.003", iens: "#{entry[:ien]},#{fm(slot)},#{clinic_ien('DEMO IHS CLINIC')},", fields: "302;309", flags: "IE") }
    assert_equal "208", checked[:fields]["302"][:internal], "#44.003 CHECK IN USER is the scheduler"
    assert checked[:fields]["309"][:internal].present?, "#44.003 CHECKED-IN holds the time"
  end
end
