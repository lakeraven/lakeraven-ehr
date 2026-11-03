# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-05: a clinic's week as a calendar, times down and days across.
# RPMS is stood in for at the gem boundary: blocks on Monday and Wednesday, a
# booked and a checked-in appointment, and a holiday on Friday.
class SchedulingClinicWeekTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  MONDAY = Date.new(2027, 1, 4)
  FRIDAY = MONDAY + 4

  RESOURCES = [
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true },
    { id: 5, name: "LOOK ONLY CLINIC", inactive: false, time_scale: 15, hospital_location_id: 8,
      view: true, overbook: false, modify_schedule: false, modify_appointments: false }
  ].freeze

  def at(date, hour, min = 0) = Time.new(date.year, date.month, date.day, hour, min)

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  def appointment(id, time, minutes, **state)
    { id: id, start_time: time, end_time: time + (minutes * 60), patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil }.merge(state)
  end

  def with_rpms(appointments: [], rules: nil, holidays: [])
    blocks = [ MONDAY, MONDAY + 2 ].map { |d| { start_time: at(d, 9), end_time: at(d, 11), slots: 2 } }
    @reads = []
    reads = @reads
    sched = RpmsRpc::Scheduling.singleton_class
    stubs = {
      sched => {
        resources: ->(*) { RESOURCES },
        slot_schedule: ->(resource:, start_date:, end_date:) { reads << [ start_date, end_date ]; blocks.select { |b| (start_date..end_date).cover?(b[:start_time].to_date) } },
        appointments: ->(resource:, start_date:, end_date:) { appointments.select { |a| (start_date..end_date).cover?(a[:start_time].to_date) } }
      }
    }.merge(scheduling_setup_stubs(rules: rules, holidays: holidays))
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  test "the week shows Monday to Friday across and the clinic's grid down, read once" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2/week", params: { date: (MONDAY + 3).iso8601 }
    end

    assert_response :ok
    assert_select "#week thead th[scope='col'][data-date]", 5
    assert_select "#week thead th[data-date='2027-01-04'] a[href='/lakeraven-ehr/scheduling/clinics/2?date=2027-01-04']"
    assert_equal %w[09:00 09:15 09:30 09:45 10:00 10:15 10:30 10:45], css_select("#week tbody th[scope='row']").map { |th| th.text.strip }
    assert_equal [ [ MONDAY, MONDAY + 6 ] ], @reads
  end

  test "an open time is a link to book it, with the places left" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2/week", params: { date: MONDAY.iso8601 }
    end

    cell = "#week tr[data-time='09:30'] td[data-date='2027-01-06']"
    assert_select "#{cell}[data-open='2'] a[data-book][href='/lakeraven-ehr/scheduling/clinics/2/appointments/new?start=2027-01-06T09%3A30']",
                  text: /2 open/
    assert_select "#{cell} a[aria-label='Book Wednesday Jan 6 at 09:30, 2 places left']"
    assert_select "#week tr[data-time='09:30'] td[data-date='2027-01-05'][data-open='']"
    assert_select "#week tr[data-time='09:30'] td[data-date='2027-01-05'] a", 0
  end

  test "each appointment shows its patient and status in words, and opens the day it is on" do
    sign_in("scheduling_user")
    booked = appointment(41, at(MONDAY, 9), 30)
    checked = appointment(42, at(MONDAY, 9, 15), 15, checkin_time: at(MONDAY, 9, 10))
    with_rpms(appointments: [ booked, checked ]) do
      get "/lakeraven-ehr/scheduling/clinics/2/week", params: { date: MONDAY.iso8601 }
    end

    assert_select "#week tr[data-time='09:00'] td[data-date='2027-01-04'] a[data-appointment='41'][data-status='booked']" \
                  "[href='/lakeraven-ehr/scheduling/clinics/2?date=2027-01-04#appointment-41']",
                  text: /MOUSE,MICKEY M.*09:00, 30 min · Booked/m
    assert_select "#week tr[data-time='09:15'] td[data-date='2027-01-04'] a[data-appointment='42'][data-status='checked']" \
                  "[aria-label='09:15, 15 minutes, MOUSE,MICKEY M, Checked in 09:10']"
    assert_select "#week tr[data-time='09:15'] td[data-date='2027-01-04'][data-open='0']", text: /Full/
  end

  test "a holiday says so under its day, and takes no booking" do
    sign_in("scheduling_user")
    with_rpms(rules: { id: 3, schedule_on_holidays: false }, holidays: [ { date: MONDAY + 2, name: "NEW YEAR OBSERVED" } ]) do
      get "/lakeraven-ehr/scheduling/clinics/2/week", params: { date: MONDAY.iso8601 }
    end

    assert_select "#week thead th[data-date='2027-01-06'] [data-closed='holiday']", text: "Holiday"
    assert_select "#week td[data-date='2027-01-06'] a[data-book]", 0
  end

  test "a scheduler who cannot book on the resource sees the places, not links" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/5/week", params: { date: MONDAY.iso8601 }
    end

    assert_select "#week a[data-book]", 0
    assert_select "#week tr[data-time='09:00'] td[data-date='2027-01-04']", text: /2 open/
  end

  test "a weekend day appears only when it has hours or bookings, and the weeks page on" do
    sign_in("scheduling_user")
    with_rpms(appointments: [ appointment(43, at(MONDAY + 5, 10), 15) ]) do
      get "/lakeraven-ehr/scheduling/clinics/2/week", params: { date: MONDAY.iso8601 }
    end

    assert_select "#week thead th[data-date='2027-01-09']"
    assert_select "#week thead th[data-date='2027-01-10']", 0
    assert_select "#previous-week[href='/lakeraven-ehr/scheduling/clinics/2/week?date=2026-12-28']"
    assert_select "#next-week[href='/lakeraven-ehr/scheduling/clinics/2/week?date=2027-01-11']"
  end

  test "the clinic list opens the week, and the day links back to it" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling"
      assert_select "a[href='/lakeraven-ehr/scheduling/clinics/2/week']", text: "DEMO IHS CLINIC"

      get "/lakeraven-ehr/scheduling/clinics/2", params: { date: MONDAY.iso8601 }
      assert_select "#week-view[href='/lakeraven-ehr/scheduling/clinics/2/week?date=2027-01-04']"
    end
  end
end
