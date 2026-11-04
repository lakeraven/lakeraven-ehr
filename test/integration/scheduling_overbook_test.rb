# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-01.2 and 01.9 to 01.11: booking a time with no room as an
# overbook, under the rules the Windows scheduler and BPRM apply, and marking
# it OVERBOOK (#44.003 field 9) as BPRM does (lakeraven-ehr#603). RPMS is stood
# in for at the gem boundary: BSDX OVERBOOK (Scheduling.overbook_allowed), BSDX
# RESOURCE USER .06 (SchedulingSetup.master_overbook?) and the mark
# (SchedulingSetup.mark_overbook).
class SchedulingOverbookTest < ActionDispatch::IntegrationTest
  DAY = Date.new(2026, 10, 28)

  def at(hour, min = 0) = Time.new(DAY.year, DAY.month, DAY.day, hour, min)

  RIGHT = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
            view: true, overbook: true, modify_schedule: false, modify_appointments: true }.freeze

  BUSY = { id: 9, start_time: Time.new(2026, 10, 28, 9), end_time: Time.new(2026, 10, 28, 9, 15),
           patient_dfn: 7, patient_name: "DUCK,DONALD", cancelled: false }.freeze

  def sign_in(keys = "scheduling_user")
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  # 08:00-12:00 one-slot block, 09:00 taken.
  def with_rpms(resource: RIGHT, allowed: true, master: false, mark: { success: true }, rules: nil)
    @calls = []
    calls = @calls
    block = { start_time: at(8), end_time: at(12), slots: 1 }
    setup = scheduling_setup_stubs(rules: rules)
    setup[RpmsRpc::SchedulingSetup.singleton_class].merge!(
      master_overbook?: ->(resource_id:, duz:) { calls << [ :master, resource_id, duz ]; master },
      mark_overbook: ->(**kw) { calls << [ :mark, kw ]; mark }
    )
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ resource ] },
        slot_schedule: ->(**) { [ block ] },
        appointments: ->(**) { [ BUSY ] },
        overbook_allowed: ->(**kw) { calls << [ :allowed, kw ]; allowed },
        add_appointment: ->(**kw) { calls << [ :add, kw ]; { success: true, appointment_id: 50 } }
      },
      RpmsRpc::Patient.singleton_class => {
        search: ->(_text) { [] },
        brief_header: ->(_dfn) { nil }
      }
    }.merge(setup)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def calls = @calls || []
  def writes = calls.map(&:first) & %i[add mark]
  def path = "/lakeraven-ehr/scheduling/clinics/2/appointments"
  def book(start: "2026-10-28T09:00", overbook: nil) = post(path, params: { booking: { patient_dfn: "3", start: start, length: "15", note: "" }, overbook: overbook }.compact)

  test "S-SCH-01.2 a full time offers Overbook only to a user with the overbook right" do
    sign_in
    with_rpms { get "/lakeraven-ehr/scheduling/clinics/2", params: { date: DAY.iso8601 } }
    assert_select "#open-times tr[data-time='09:00'] a[data-overbook]", text: "Overbook"

    with_rpms(resource: RIGHT.merge(overbook: false)) { get "/lakeraven-ehr/scheduling/clinics/2", params: { date: DAY.iso8601 } }
    assert_select "#open-times tr[data-time='09:00'] a", count: 0
  end

  test "S-SCH-01.10 a full time is offered as an overbook, and once confirmed it is booked and marked OVERBOOK" do
    sign_in
    with_rpms do
      book
      assert_response :conflict
      assert_select "#overbook-offer", text: /book it as an overbook/
      assert_select "#booking-form button[name='overbook'][value='1']", text: "Book as an overbook"
      assert_empty writes, "nothing is filed until the scheduler confirms"

      book(overbook: "1")
      assert_redirected_to "/lakeraven-ehr/scheduling/clinics/2?date=2026-10-28"
      assert_equal %i[add mark], writes
      assert_equal({ hospital_location_id: 3, start_time: at(9), patient_dfn: 3 }, calls.find { |c| c.first == :mark }.last)
      assert_equal({ hospital_location_id: 3, start_time: at(9), resource_id: 2 }, calls.find { |c| c.first == :allowed }.last)
    end
  end

  test "S-SCH-01.11 at the clinic's daily maximum, without the master right or SDZSUP, a full time is refused" do
    sign_in
    with_rpms(allowed: false) do
      book(overbook: "1")
    end

    assert_response :conflict
    assert_select "[role='alert']", text: /full/
    assert_empty writes
  end

  test "S-SCH-01.11 the master overbook right books past the clinic's daily maximum" do
    sign_in
    with_rpms(allowed: false, master: true) do
      book(overbook: "1")
    end

    assert_response :redirect
    assert_equal %i[add mark], writes
    assert_equal [ :master, 2, 208 ], calls.find { |c| c.first == :master }
  end

  test "S-SCH-01.9 a time outside every block needs the master right or SDZSUP; the overbook right alone is refused" do
    sign_in
    with_rpms { book(start: "2026-10-28T13:00", overbook: "1") }
    assert_response :conflict
    assert_empty writes

    sign_in "scheduling_user,scheduling_supervisor"
    with_rpms do
      book(start: "2026-10-28T13:00")
      assert_select "#overbook-offer"
      book(start: "2026-10-28T13:00", overbook: "1")
      assert_response :redirect
      assert_equal %i[add mark], writes
      refute(calls.any? { |c| c.first == :allowed }, "SDZSUP is not held to the daily maximum")
    end
  end

  test "S-SCH-01.7 not even SDZSUP overbooks a clinic past its inactivate date" do
    sign_in "scheduling_user,scheduling_supervisor"
    rules = { id: 3, display_begins: nil, schedule_on_holidays: false, max_future_days: nil, prohibit_access: false,
              inactivate_date: DAY - 1, reactivate_date: nil }
    with_rpms(rules: rules) do
      book(overbook: "1")
    end

    assert_response :conflict
    assert_empty writes
  end

  test "S-SCH-01.10 when RPMS does not mark the overbook, the booking stands and the scheduler is told" do
    sign_in
    with_rpms(mark: { success: false, error: "the clinic holds no appointment for the patient" }) do
      book(overbook: "1")
      follow_redirect!
    end

    assert_select "#clinic-alert", text: /did not mark it as an overbook/
  end

  test "S-SCH-01.11 a failed overbook check refuses" do
    sign_in
    with_rpms do
      RpmsRpc::Scheduling.singleton_class.define_method(:overbook_allowed) { |**| raise RpmsRpc::Client::RpcError, "BSDX OVERBOOK: no YES or NO in the reply" }
      book(overbook: "1")
    end

    assert_response :conflict
    assert_empty writes
  end
end
