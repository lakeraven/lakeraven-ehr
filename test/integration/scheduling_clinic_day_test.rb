# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-05.2 and S-SCH-05.3: a clinic's day shows its hours, and every
# appointment's status. RPMS is stood in for at the gem boundary.
class SchedulingClinicDayTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  DAY = Date.new(2027, 1, 6)
  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: true, modify_schedule: true, modify_appointments: true }.freeze

  def at(hour, min = 0) = Time.new(DAY.year, DAY.month, DAY.day, hour, min)

  def appointment(id, time, **state)
    { id: id, start_time: time, end_time: time + 900, patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil }.merge(state)
  end

  def sign_in
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" }
  end

  def with_rpms(appointments: [], blocks: nil, overbook_at: [], cancelled: {}, **setup)
    blocks ||= [ { start_time: at(9), end_time: at(11), slots: 2, access_type_id: 1 },
                 { start_time: at(0), end_time: at(9), slots: 0, access_type_id: 0 } ]
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ RESOURCE ] },
        slot_schedule: ->(**) { blocks },
        appointments: ->(**) { appointments }
      }
    }.merge(scheduling_setup_stubs(**setup))
    stubs[RpmsRpc::SchedulingSetup.singleton_class][:overbook?] = ->(start_time:, **) { overbook_at.include?(start_time) }
    stubs[RpmsRpc::SchedulingSetup.singleton_class][:cancelled_by] = ->(start_time:, **) { cancelled[start_time] }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def show = get("/lakeraven-ehr/scheduling/clinics/2", params: { date: DAY.iso8601 })

  test "S-SCH-05.2 each block shows with its access type and slot count, and the padding blocks do not" do
    sign_in
    with_rpms { show }

    assert_response :ok
    assert_select "#blocks tbody tr", 1
    assert_select "#blocks tr[data-block='09:00'] td[data-access-type='1']", text: "DEMO GENERAL"
    assert_select "#blocks tr[data-block='09:00'] td[data-slots='2']"
  end

  test "S-SCH-05.2 a holiday shows the whole day blocked" do
    sign_in
    with_rpms(rules: { id: 3, schedule_on_holidays: false }, holidays: [ { date: DAY, name: "NEW YEAR OBSERVED" } ]) { show }

    assert_select "#day-closed", text: /Holiday: the clinic takes no appointments/
    assert_select "#blocks", 0
    assert_select "#open-times", 0
  end

  test "S-SCH-05.2 a clinic that schedules on holidays shows its hours as on any day" do
    sign_in
    with_rpms(rules: { id: 3, schedule_on_holidays: true }, holidays: [ { date: DAY, name: "NEW YEAR OBSERVED" } ]) { show }

    assert_select "#day-closed", 0
    assert_select "#blocks tr[data-block='09:00']"
  end

  test "S-SCH-05.3 each appointment shows its status, who cancelled, and whether it is an overbook" do
    sign_in
    with_rpms(appointments: [ appointment(1, at(9)),
                              appointment(2, at(9, 15), checkin_time: at(9, 10)),
                              appointment(3, at(9, 30), checkin_time: at(9, 25), checkout_time: at(9, 45)),
                              appointment(4, at(9, 45), cancelled: true),
                              appointment(5, at(10), cancelled: true),
                              appointment(6, at(10, 15), no_show: true),
                              appointment(7, at(10, 30)) ],
              overbook_at: [ at(10, 30) ],
              cancelled: { at(9, 45) => :clinic, at(10) => :patient }) { show }

    {
      1 => "Booked", 2 => "Checked in 09:10", 3 => "Checked out 09:45", 4 => "Cancelled by the clinic",
      5 => "Cancelled by the patient", 6 => "No-show", 7 => "Booked"
    }.each { |id, words| assert_select "#appointment-#{id} [data-status-badge]", text: words }
    assert_select "#appointments [data-overbook]", 1
    assert_select "#appointment-7 [data-overbook]", text: "Overbook"
  end

  test "S-SCH-05.3 a cancellation RPMS does not attribute still reads as cancelled" do
    sign_in
    with_rpms(appointments: [ appointment(1, at(9), cancelled: true) ]) { show }

    assert_select "#appointment-1 [data-status-badge]", text: "Cancelled"
  end
end
