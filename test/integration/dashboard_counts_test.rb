# frozen_string_literal: true

require "test_helper"

# #812: every count on the dashboard is RPMS's and links to where the work is
# done, or is not shown. RPMS is stood in for at the gem boundary with what a
# live rpms-ydb e9b78c8 build answered the scheduler persona on 2026-11-03,
# after it booked twice into DEMO IHS CLINIC and cancelled one: BSDX RESOURCES
# named two clinics, and BSDX ALL APPOINTMENTS returned the one booking it
# kept, leaving out the cancelled one. test/integration/live_dashboard_counts_test.rb
# proves the same against the running build.
class DashboardCountsTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  TODAY = Date.new(2026, 11, 3)

  RESOURCES = [
    { id: 1, name: "DEMO PRIMARY CARE", inactive: false, time_scale: 15, hospital_location_id: 6,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true },
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true },
    # Not on the persona's BSDX rights: a supervisor sees it, a scheduler does not.
    { id: 7, name: "OTHER CLINIC", inactive: false, time_scale: 15, hospital_location_id: 9,
      view: false, overbook: false, modify_schedule: false, modify_appointments: false }
  ].freeze

  ALL_APPOINTMENTS = [
    { start_time: Time.new(2026, 11, 3, 8, 0, 0, "-08:00"), end_time: Time.new(2026, 11, 3, 8, 15, 0, "-08:00"),
      patient_dfn: 3, resource_name: "DEMO IHS CLINIC" }
  ].freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  # Stands in for RpmsRpc::Scheduling's two reads, recording the dates asked for.
  def with_scheduling(all_appointments: ->(**) { ALL_APPOINTMENTS })
    asked = (@asked = [])
    restores = [
      singleton_method_restore(RpmsRpc::Scheduling, :resources),
      singleton_method_restore(RpmsRpc::Scheduling, :all_appointments)
    ]
    RpmsRpc::Scheduling.define_singleton_method(:resources) { |*| asked << :resources; RESOURCES }
    RpmsRpc::Scheduling.define_singleton_method(:all_appointments) { |**range| asked << range; all_appointments.call(**range) }
    travel_to(TODAY.to_time.change(hour: 9)) { yield }
  ensure
    restores&.each(&:call)
  end

  def counts
    css_select("#clinic-counts tr[data-resource]").to_h { |tr| [ tr["data-resource"].to_i, tr.at_css("td[data-count]")["data-count"].to_i ] }
  end

  test "S-SCH-05.1 and 05.3 a scheduler sees today's appointments in each of their clinics, each linked to that clinic's day" do
    sign_in("scheduling_user")
    with_scheduling do
      get "/lakeraven-ehr/dashboard"
    end

    assert_response :ok
    assert_equal({ 1 => 0, 2 => 1 }, counts, "one row per clinic BSDX names the user on; RPMS's count, a real zero included")
    assert_includes @asked, { start_date: TODAY, end_date: TODAY }, "today's appointments, read for today"
    assert_select "#clinic-counts tr[data-resource='2'] a[href='/lakeraven-ehr/scheduling/clinics/2?date=2026-11-03']",
      text: /1\s+appointment today at DEMO IHS CLINIC/
    assert_select "#clinic-counts tr[data-resource='1'] a[href='/lakeraven-ehr/scheduling/clinics/1?date=2026-11-03']"
  end

  test "S-SCH-05.1 a scheduling supervisor sees every clinic of the facility" do
    sign_in("scheduling_supervisor")
    with_scheduling { get "/lakeraven-ehr/dashboard" }

    assert_equal({ 1 => 0, 2 => 1, 7 => 0 }, counts)
  end

  test "when RPMS does not answer, the dashboard says so instead of showing zero" do
    sign_in("scheduling_user")
    with_scheduling(all_appointments: ->(**) { raise RpmsRpc::Client::RpcError, "broker timeout" }) do
      get "/lakeraven-ehr/dashboard"
    end

    assert_response :ok
    assert_select "#clinic-counts-unread", text: /could not be read from RPMS/
    assert_select "#clinic-counts", count: 0
  end

  test "a user who does not schedule sees no count, and RPMS is not asked for one" do
    sign_in("")
    with_scheduling { get "/lakeraven-ehr/dashboard" }

    assert_response :ok
    assert_empty @asked
    assert_select "#clinic-counts", count: 0
    assert_select "#no-counts"
  end

  test "no count is a constant: the made-up cases, tasks and referrals are gone" do
    sign_in("scheduling_user")
    with_scheduling { get "/lakeraven-ehr/dashboard" }

    [ "Active Cases", "My Tasks", "Pending Referrals" ].each { |label| assert_not_includes response.body, label }
  end

  # BSDX is IHS-only (#647): without bprm_scheduling there is no clinic day to link to.
  test "on a backend without bprm_scheduling a scheduler sees no appointment count" do
    sign_in("scheduling_user")
    with_restricted_backend do
      with_scheduling { get "/lakeraven-ehr/dashboard" }
    end

    assert_response :ok
    assert_empty @asked
    assert_select "#clinic-counts", count: 0
  end
end
