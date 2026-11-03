# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-14: a scheduling supervisor sets a clinic's hours, its blocks in
# BSDX ACCESS BLOCK. RPMS is stood in for at the gem boundary: the blocks a day
# holds, its appointments, and the two writes, recorded.
class SchedulingClinicHoursTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  MONDAY = Date.new(2027, 1, 4)

  RESOURCES = [
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true },
    { id: 5, name: "BOOK ONLY CLINIC", inactive: false, time_scale: 15, hospital_location_id: 8,
      view: true, overbook: false, modify_schedule: false, modify_appointments: true }
  ].freeze

  def at(date, hour, min = 0) = Time.new(date.year, date.month, date.day, hour, min)

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  # Stands in for RpmsRpc::Scheduling; records each removal and block filed.
  def with_rpms(appointments: [], add: ->(_args) { { success: true, availability_id: 77 } })
    @writes = []
    log = @writes
    sched = RpmsRpc::Scheduling.singleton_class
    stubs = {
      sched => {
        resources: ->(*) { RESOURCES },
        slot_schedule: ->(**) { [] },
        appointments: ->(resource:, start_date:, end_date:) { appointments.select { |a| (start_date..end_date).cover?(a[:start_time].to_date) } },
        cancel_availability_by_date: ->(**args) { log << [ :cancel, args ]; { success: true } },
        add_availability: ->(**args) { log << [ :add, args ]; add.call(args) }
      }
    }.merge(scheduling_setup_stubs)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def writes = @writes || []

  def added = writes.select { |kind, _| kind == :add }.map(&:last)

  def hours_params(**changes)
    { hours: { weekdays: %w[1 3], opens: "08:00", closes: "12:00", slots: "2", access_type_id: "1",
               first_date: MONDAY.iso8601, last_date: (MONDAY + 13).iso8601 }.merge(changes) }
  end

  def appointment(time, minutes: 20, **state)
    { id: 40, start_time: time, end_time: time + (minutes * 60), patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil }.merge(state)
  end

  test "S-SCH-14.1 each chosen weekday in the range gets one block of the hours, and no other day changes" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/2/hours", params: hours_params

      assert_redirected_to "/lakeraven-ehr/scheduling/clinics/2?date=2027-01-04"
    end

    days = [ MONDAY, MONDAY + 2, MONDAY + 7, MONDAY + 9 ]
    assert_equal days.map { |d| { resource: "DEMO IHS CLINIC", start_time: at(d, 8), end_time: at(d, 12), slots: 2, access_type_id: 1 } }, added
    assert_equal days, writes.select { |kind, _| kind == :cancel }.map { |_, args| args[:start_date] }
  end

  test "S-SCH-14.4 a day set again has its blocks removed before the new block is filed" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/2/hours", params: hours_params(weekdays: %w[1], last_date: MONDAY.iso8601)
    end

    assert_equal [ [ :cancel, { resource_id: 2, start_date: MONDAY, end_date: MONDAY } ], :add ], writes.map { |kind, args| kind == :add ? kind : [ kind, args ] }
  end

  test "S-SCH-14.3 a bad value is refused, named, and nothing is filed" do
    sign_in("scheduling_supervisor")
    {
      { closes: "08:00" } => "Closes must be after the start time",
      { slots: "0" } => "Slots must be greater than or equal to 1",
      { access_type_id: "" } => "Access type is required",
      { access_type_id: "9" } => "Access type is not an active access type",
      { last_date: (MONDAY - 1).iso8601 } => "Last date cannot be before the first date",
      { weekdays: [] } => "Weekdays are required"
    }.each do |change, message|
      with_rpms do
        post "/lakeraven-ehr/scheduling/clinics/2/hours", params: hours_params(**change)

        assert_response :unprocessable_content
        assert_select "#hours-errors li", text: /#{Regexp.escape(message)}/
        assert_empty writes, "#{change.inspect} should file nothing"
      end
    end
  end

  test "S-SCH-14.5 an appointment the new hours would not cover is named, and nothing changes" do
    sign_in("scheduling_supervisor")
    late = appointment(at(MONDAY + 2, 14))
    with_rpms(appointments: [ late, appointment(at(MONDAY, 9)) ]) do
      post "/lakeraven-ehr/scheduling/clinics/2/hours", params: hours_params

      assert_response :conflict
      assert_select "#hours-conflicts li[data-appointment='40']", text: /Wed Jan 6, 2027 at 14:00/, count: 1
      assert_empty writes
    end
  end

  test "S-SCH-14.5 a cancelled appointment or a no-show outside the new hours does not stop them" do
    sign_in("scheduling_supervisor")
    with_rpms(appointments: [ appointment(at(MONDAY, 14), cancelled: true), appointment(at(MONDAY, 15), no_show: true) ]) do
      post "/lakeraven-ehr/scheduling/clinics/2/hours", params: hours_params(weekdays: %w[1], last_date: MONDAY.iso8601)

      assert_response :redirect
    end
    assert_equal 1, added.size
  end

  test "an RPMS refusal stops the change at that day and says which days were set" do
    sign_in("scheduling_supervisor")
    refuse_second = ->(args) { args[:start_time].to_date == MONDAY + 2 ? { success: false, error: "0^134234182" } : { success: true, availability_id: 7 } }
    with_rpms(add: refuse_second) do
      post "/lakeraven-ehr/scheduling/clinics/2/hours", params: hours_params

      assert_response :unprocessable_content
      assert_select "[role='alert']", text: /refused the hours for Jan 6, 2027/
      assert_select "#hours-partial", text: /set through Jan 4, 2027/
    end
    assert_equal [ MONDAY, MONDAY + 2 ], added.map { |a| a[:start_time].to_date }
  end

  test "S-SCH-14.6 without SDZMENU or SDZSUP, a clinic's hours cannot be set" do
    sign_in("registration_menu")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/2/hours", params: hours_params

      assert_response :forbidden
      assert_empty writes
    end
  end

  test "a scheduler without the resource's modify-schedule right cannot set its hours, and is not offered to" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/5", params: { date: MONDAY.iso8601 }
      assert_select "#set-hours", count: 0

      post "/lakeraven-ehr/scheduling/clinics/5/hours", params: hours_params

      assert_response :forbidden
      assert_empty writes
    end
  end

  test "a scheduler with the modify-schedule right is offered the hours form" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2", params: { date: MONDAY.iso8601 }
      assert_select "#set-hours[href='/lakeraven-ehr/scheduling/clinics/2/hours/new']"

      get "/lakeraven-ehr/scheduling/clinics/2/hours/new"
      assert_response :ok
      assert_select "#hours-form select[name='hours[access_type_id]'] option[value='1']", text: "DEMO GENERAL"
    end
  end
end
