# frozen_string_literal: true

require "test_helper"

# #875, rpms-ux S-SCH-13.5: a scheduler lists the appointments in their clinics
# past their time with no check-in, check-out, cancellation or no-show
# recorded, and the dashboard counts today's, linked to that list. RPMS is
# stood in for at the wire with the replies a live rpms-ydb 7c3119b build gave
# the scheduler persona on 2026-11-04, after
# test/integration/live_appointments_needing_action_test.rb booked five
# appointments into DEMO IHS CLINIC on Oct 20, 2026 and took four of them to a
# recorded state: 35 untouched, 36 checked in, 37 checked in and out, 38
# cancelled, 39 a no-show. The gem parses them as it would live.
class AppointmentsNeedingActionTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  DAY = Date.new(2026, 10, 20)
  LIST = "/lakeraven-ehr/scheduling/needing_action"

  CAPTURED = {
    "BSDX RESOURCES" =>
      "3\u0000I00010RESOURCEID^T00030RESOURCE_NAME^T00010INACTIVE^I00010TIMESCALE^I00010HOSPITAL_LOCATION_ID^" \
      "T00030LETTER_TEXT^T00030NO_SHOW_LETTER^T00030CLINIC_CANCELLATION_LETTER^I00010VIEW^I00010OVERBOOK^" \
      "I00010MODIFY_SCHEDULE^I00010MODIFY_APPOINTMENTS\u001e" \
      "1^DEMO PRIMARY CARE^0^15^6^^^^1^1^1^1\u001e2^DEMO IHS CLINIC^0^15^3^^^^1^1^1^1\u001e",
    # Leaves out the cancelled appointment and the no-show (STCOMM^BSDX05).
    "BSDX ALL APPOINTMENTS" => [
      "D00030START_TIME^D00030END_TIME^I00010PAT_ID^T00030RES_NAME",
      "OCT 20,2026 10:30^OCT 20,2026 10:45^3^DEMO IHS CLINIC",
      "OCT 20,2026 13:00^OCT 20,2026 13:15^3^DEMO IHS CLINIC",
      "OCT 20,2026 13:30^OCT 20,2026 13:45^3^DEMO IHS CLINIC"
    ],
    "BSDX CREATE APPT SCHEDULE" =>
      "5\u0000I00020APPOINTMENTID^D00030START_TIME^D00030END_TIME^D00030CHECKIN^D00030AUXTIME^I00020PATIENTID^" \
      "T00030PATIENTNAME^T00030RESOURCENAME^I00005NOSHOW^T00020HRN^I00005ACCESSTYPEID^I00005WALKIN^D00030CHECKOUT^" \
      "I00020VPROVIDER^T00020CANCELLED^T00250NOTE\u001e" \
      "39^OCT 20,2026 08:45^OCT 20,2026 09:00^^^3^MOUSE,MICKEY M^DEMO IHS CLINIC^1^1001^0^0^^^0^\u001e" \
      "37^OCT 20,2026 10:30^OCT 20,2026 10:45^OCT 20,2026 10:35^^3^MOUSE,MICKEY M^DEMO IHS CLINIC^0^1001^0^0^Oct 20, 2026 10:50^206^0^\u001e" \
      "38^OCT 20,2026 11:00^OCT 20,2026 11:15^^^3^MOUSE,MICKEY M^DEMO IHS CLINIC^0^1001^0^0^^^1^\u001e" \
      "36^OCT 20,2026 13:00^OCT 20,2026 13:15^OCT 20,2026 13:05^^3^MOUSE,MICKEY M^DEMO IHS CLINIC^0^1001^0^0^^206^0^\u001e" \
      "35^OCT 20,2026 13:30^OCT 20,2026 13:45^^^3^MOUSE,MICKEY M^DEMO IHS CLINIC^0^1001^0^0^^^0^\u001e"
  }.freeze

  # Answers the three BSDX reads with the captured replies, the way the live
  # client handed them over, and records each call. A day other than DAY has
  # no appointments: the reply's header alone.
  def with_rpms(replies = CAPTURED)
    calls = (@calls = [])
    client = RpmsRpc.client
    %i[call_rpc call_rpc_global_array].each do |name|
      original = client.method(name)
      client.define_singleton_method(name) do |rpc, *params|
        next original.call(rpc, *params) unless replies.key?(rpc)

        calls << [ rpc, *params ]
        reply = replies[rpc]
        raise reply if reply.is_a?(Exception)

        dated = rpc != "BSDX RESOURCES"
        other_day = dated && !params.grep(/\A3261020(\.|\z)/).any?
        if reply.is_a?(Array)
          RpmsRpc::Reply.from_wire(other_day ? reply.first(1) : reply)
        else
          other_day ? reply[/\A.*?\u001e/m] : reply
        end
      end
    end
    yield
  end

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  def visit(path, at: DAY.to_time.change(hour: 15), **params)
    travel_to(at) { get path, params: params }
  end

  def rows
    css_select("#needing-action tr[data-appointment]").map { |tr| [ tr["data-appointment"], tr.at_css("td[data-start]")["data-start"], tr["data-resource"], tr["data-patient"] ] }
  end

  def schedules_read = @calls.select { |c| c.first == "BSDX CREATE APPT SCHEDULE" }

  test "S-SCH-13.5 exactly the appointment past its time with nothing recorded is listed, linked to its clinic's day" do
    sign_in("scheduling_user")
    with_rpms { visit LIST, from: DAY.iso8601, to: DAY.iso8601 }

    assert_response :ok
    assert_equal [ %w[35 2026-10-20T13:30 2 3] ], rows, "not the checked-in, checked-out, cancelled or no-show ones"
    assert_select "#needing-action tr[data-appointment='35'] th", text: "MOUSE,MICKEY M"
    assert_select "#needing-action tr[data-appointment='35'] a[href='/lakeraven-ehr/scheduling/clinics/2?date=2026-10-20#appointment-35']",
      text: /Open the day\s+at DEMO IHS CLINIC for MOUSE,MICKEY M/
    assert_select "#needing-action caption", text: /1 appointment needing action from Oct 20, 2026 to Oct 20, 2026/
    assert_includes @calls, [ "BSDX ALL APPOINTMENTS", "3261020", "3261020" ]
    assert_equal [ [ "BSDX CREATE APPT SCHEDULE", "DEMO IHS CLINIC", "3261020.0001", "3261020.2359", "" ] ], schedules_read,
      "only the clinic with an appointment that day is read; DEMO PRIMARY CARE has none"
  end

  test "S-SCH-13.5 an appointment whose time has not come is not listed" do
    sign_in("scheduling_user")
    with_rpms { visit LIST, at: DAY.to_time.change(hour: 13, min: 15), from: DAY.iso8601, to: DAY.iso8601 }

    assert_select "#no-needing-action", text: /No appointments from Oct 20, 2026 to Oct 20, 2026 need action/
    assert_select "#needing-action", count: 0
  end

  test "S-SCH-13.5 the list is today unless the scheduler chooses other dates, and is offered from the scheduling home" do
    sign_in("scheduling_user")
    with_rpms do
      visit LIST
      assert_select "#from[value='2026-10-20']"
      assert_select "#to[value='2026-10-20']"
      assert_equal [ %w[35 2026-10-20T13:30 2 3] ], rows

      visit "/lakeraven-ehr/scheduling"
      assert_select "a#needing-action-link[href='#{LIST}']", text: "Appointments needing action"
    end
  end

  test "S-SCH-13.5 dates that are not dates, the wrong way round, or more than 31 days are refused and RPMS is not asked" do
    sign_in("scheduling_user")
    with_rpms do
      [ { from: "2026-13-01", to: "2026-10-20" }, { from: "2026-10-20", to: "" },
        { from: "2026-10-21", to: "2026-10-20" }, { from: "2026-09-19", to: "2026-10-20" } ].each do |dates|
        visit LIST, **dates

        assert_response :ok
        assert_select "#from_error", { minimum: 1 }, "#{dates}: the error is named next to the field"
        assert_select "#needing-action", count: 0
      end
      visit LIST, from: "2026-09-20", to: "2026-10-20"
      assert_select "#from_error", count: 0
    end
    assert_equal 1, @calls.count { |c| c.first == "BSDX ALL APPOINTMENTS" }, "only the 31-day range was read"
  end

  test "S-SCH-13.5 the clinics are the scheduler's own: a clinic BSDX does not name them on is not read" do
    hidden = CAPTURED["BSDX RESOURCES"].sub("2^DEMO IHS CLINIC^0^15^3^^^^1^1^1^1", "2^DEMO IHS CLINIC^0^15^3^^^^0^0^0^0")
    sign_in("scheduling_user")
    with_rpms(CAPTURED.merge("BSDX RESOURCES" => hidden)) { visit LIST, from: DAY.iso8601, to: DAY.iso8601 }

    assert_select "#no-needing-action"
    assert_empty schedules_read
  end

  test "S-SCH-13.5 a scheduling supervisor sees every clinic's" do
    hidden = CAPTURED["BSDX RESOURCES"].sub("2^DEMO IHS CLINIC^0^15^3^^^^1^1^1^1", "2^DEMO IHS CLINIC^0^15^3^^^^0^0^0^0")
    sign_in("scheduling_supervisor")
    with_rpms(CAPTURED.merge("BSDX RESOURCES" => hidden)) { visit LIST, from: DAY.iso8601, to: DAY.iso8601 }

    assert_equal [ %w[35 2026-10-20T13:30 2 3] ], rows
  end

  test "S-SCH-13.5 when RPMS does not answer, the list says so instead of showing none" do
    sign_in("scheduling_user")
    with_rpms(CAPTURED.merge("BSDX CREATE APPT SCHEDULE" => RpmsRpc::Client::RpcError.new("broker timeout"))) { visit LIST }

    assert_response :ok
    assert_select "#needing-action-unread", text: /could not be read from RPMS/
    assert_select "#no-needing-action", count: 0
    assert_select "#needing-action-window", { count: 1 }, "the dates can still be changed"
  end

  test "S-SCH-13.8 a user who may not open scheduling is refused the list, and RPMS is not asked" do
    sign_in("")
    with_rpms { visit LIST }

    assert_response :forbidden
    assert_empty @calls
  end

  test "S-SCH-13.5 on a backend without bprm_scheduling there is no list" do
    sign_in("scheduling_user")
    with_restricted_backend { visit LIST }

    assert_response :not_found
  end

  # The dashboard (#812's pattern): RPMS's count, a real zero included, linked
  # to where the work is done; a failed read is said so.

  test "S-SCH-13.5 the dashboard counts today's appointments needing action, linked to the list" do
    sign_in("scheduling_user")
    with_rpms { visit "/lakeraven-ehr/dashboard" }

    assert_response :ok
    assert_select "#needing-action-count[data-count='1'] a[href='#{LIST}']",
      text: /1\s+appointment today in your clinics past their time with no check-in, check-out, cancellation or no-show/
    assert_includes @calls, [ "BSDX ALL APPOINTMENTS", "3261020", "3261020" ], "today's, the list's default"
  end

  test "S-SCH-13.5 before any appointment's time has come the dashboard counts 0" do
    sign_in("scheduling_user")
    with_rpms { visit "/lakeraven-ehr/dashboard", at: DAY.to_time.change(hour: 8) }

    assert_select "#needing-action-count[data-count='0'] a", text: /0\s+appointments today/
  end

  test "S-SCH-13.5 when RPMS does not answer, the dashboard says so instead of showing zero" do
    sign_in("scheduling_user")
    with_rpms(CAPTURED.merge("BSDX CREATE APPT SCHEDULE" => RpmsRpc::Client::RpcError.new("broker timeout"))) { visit "/lakeraven-ehr/dashboard" }

    assert_response :ok
    assert_select "#needing-action-count-unread", text: /could not be read from RPMS/
    assert_select "#needing-action-count", count: 0
  end

  test "S-SCH-13.8 a user who does not schedule sees no count, and RPMS is not asked for one" do
    sign_in("")
    with_rpms { visit "/lakeraven-ehr/dashboard" }

    assert_response :ok
    assert_empty @calls
    assert_select "#needing-action-count", count: 0
    assert_select "a[href='#{LIST}']", count: 0
  end
end
