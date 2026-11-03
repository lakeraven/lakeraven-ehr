# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-02.8 to 02.10: a scheduler moves an appointment to another time,
# at the same clinic or another. RPMS is stood in for at the gem boundary: the
# new time is booked first (BSDX ADD NEW APPOINTMENT) and only then is the
# original cancelled (BSDX CANCEL APPOINTMENT), so a refused new time never
# costs the patient the appointment they had.
class SchedulingRescheduleAppointmentTest < ActionDispatch::IntegrationTest
  DAY = Date.new(2026, 10, 28)
  NEXT = Date.new(2026, 10, 30)

  def at(hour, min = 0, day: DAY) = Time.new(day.year, day.month, day.day, hour, min)

  CLINIC = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
             view: true, overbook: false, modify_schedule: true, modify_appointments: true }.freeze
  OTHER = CLINIC.merge(id: 1, name: "DEMO PRIMARY CARE", hospital_location_id: 6).freeze
  LOOK_ONLY = CLINIC.merge(id: 5, name: "DEMO DENTAL", hospital_location_id: 9, modify_appointments: false).freeze

  REASONS = { entries: [
    { ien: 4, pieces: [ "TRAVEL DIFFICULTY", "P", "" ] },
    { ien: 7, pieces: [ "CLINIC STAFFING", "C", "" ] },
    { ien: 11, pieces: [ "OTHER", "B", "" ] }
  ] }.freeze

  def original(**state)
    { id: 8, start_time: at(9), end_time: at(9, 30), patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil, note: "follow-up: bring meds; fasting" }.merge(state)
  end

  def sign_in
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" }
  end

  # listed: the appointments each resource holds, by resource name; slots: the
  # places in each day's 08:00-17:00 block.
  def with_rpms(listed: { "DEMO IHS CLINIC" => [ original ] }, slots: 1, add: nil, cancel: nil, rules: nil)
    @calls = []
    add ||= ->(**) { { success: true, appointment_id: 21 } }
    cancel ||= ->(*) { { success: true } }
    calls = @calls
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ CLINIC, OTHER, LOOK_ONLY ] },
        slot_schedule: ->(start_date:, **) { [ { start_time: Time.new(start_date.year, start_date.month, start_date.day, 8), end_time: Time.new(start_date.year, start_date.month, start_date.day, 17), slots: slots } ] },
        appointments: ->(resource:, start_date:, **) { listed.fetch(resource, []).select { |a| a[:start_time].to_date == start_date } },
        add_appointment: ->(**kw) { calls << [ :add, kw ]; add.call(**kw) },
        cancel_appointment: ->(id, **kw) { calls << [ :cancel, kw.merge(id: id) ]; cancel.call(id, kw) }
      },
      RpmsRpc::DdrFileman.singleton_class => { lister: ->(**) { REASONS } }
    }.merge(scheduling_setup_stubs(rules: rules))
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def calls = @calls || []

  def path = "/lakeraven-ehr/scheduling/clinics/2/appointments/8/reschedule"

  def move_params(**changes)
    { date: DAY.iso8601, reschedule: { resource_id: "1", start: "2026-10-30T10:15", whom: "PC", reason_ien: "4", extra: "" }.merge(changes) }
  end

  test "S-SCH-02.8 the appointment moves to another clinic: the new time is booked with its note and length, then the original is cancelled with the type, reason and where it went" do
    sign_in
    with_rpms do
      post path, params: move_params(extra: "patient asked")

      assert_redirected_to "/lakeraven-ehr/scheduling/clinics/1?date=2026-10-30"
      assert_equal %i[add cancel], calls.map(&:first), "booked first, cancelled second"
      added = calls.first.last
      assert_equal [ 3, "DEMO PRIMARY CARE", at(10, 15, day: NEXT), at(10, 45, day: NEXT), 30, "follow-up  bring meds  fasting".squish ],
                   added.values_at(:patient_dfn, :resource, :start_time, :end_time, :length_minutes, :note)
      assert_equal({ id: 8, type: "PC", reason: 4, note: "Rescheduled to Oct 30, 2026 1015 DEMO PRIMARY CARE. patient asked" }, calls.last.last)
    end
  end

  test "S-SCH-02.8 the move page offers the clinics I book on and the open times there at the original's length" do
    sign_in
    with_rpms(listed: { "DEMO IHS CLINIC" => [ original ], "DEMO PRIMARY CARE" => [ original(id: 30, start_time: at(10, day: NEXT), end_time: at(10, 30, day: NEXT), patient_dfn: 9) ] }) do
      get path, params: { date: DAY.iso8601, to: "1", on: NEXT.iso8601, whom: "C" }
    end

    assert_response :ok
    assert_equal [ "DEMO IHS CLINIC", "DEMO PRIMARY CARE" ], css_select("#reschedule-find select#to option").map(&:text)
    times = css_select("#reschedule-form label[data-time]").map { |l| l["data-time"] }
    assert_includes times, "09:30"
    refute_includes times, "09:45", "a 30-minute appointment at 09:45 runs into the full 10:00"
    refute_includes times, "10:15"
    assert_equal [ "CLINIC STAFFING", "OTHER" ], css_select("#reschedule-form select option").map(&:text).drop(1)
  end

  test "S-SCH-02.9 a checked-in, cancelled or no-show appointment cannot be moved" do
    sign_in
    [ original(checkin_time: at(8, 55)), original(cancelled: true), original(no_show: true) ].each do |state|
      with_rpms(listed: { "DEMO IHS CLINIC" => [ state ] }) do
        get path, params: { date: DAY.iso8601 }
        assert_response :conflict
        post path, params: move_params
        assert_response :conflict
      end
    end
    assert_empty calls
  end

  test "S-SCH-02.10 a full new time is refused and the original stays booked" do
    sign_in
    full = { "DEMO IHS CLINIC" => [ original ], "DEMO PRIMARY CARE" => [ original(id: 30, start_time: at(10, day: NEXT), end_time: at(11, day: NEXT), patient_dfn: 9) ] }
    with_rpms(listed: full) do
      post path, params: move_params
    end

    assert_response :conflict
    assert_select "#reschedule-alert", text: /full.*not moved/m
    assert_empty calls, "nothing is booked or cancelled"
  end

  test "S-SCH-02.10 a new time RPMS refuses leaves the original booked, with RPMS's reason" do
    sign_in
    with_rpms(add: ->(**) { { success: false, error: "BSDX07 Error: Unable to make appointment.  MAKE^BSDAPI returned error code: 1^Patient already has appt" } }) do
      post path, params: move_params
    end

    assert_response :unprocessable_content
    assert_select "#reschedule-alert", text: /already has appt/
    assert_equal [ :add ], calls.map(&:first), "the original is never cancelled"
  end

  test "S-SCH-02.10 when the original cannot be cancelled, the new booking is cancelled again and the original stays" do
    sign_in
    refuse_original = ->(id, _kw) { id == 8 ? { success: false, error: "Another user is working with this patient's record." } : { success: true } }
    with_rpms(cancel: refuse_original) do
      post path, params: move_params
    end

    assert_response :unprocessable_content
    assert_equal [ [ :add, nil ], [ :cancel, 8 ], [ :cancel, 21 ] ], calls.map { |kind, kw| [ kind, kw[:id] ] }
    assert_select "#reschedule-alert", text: /not moved.*Another user.*still booked/m
  end

  test "S-SCH-02.10 when neither cancel goes through, the scheduler is told the patient holds both" do
    sign_in
    with_rpms(cancel: ->(*) { { success: false, error: "lock" } }) do
      post path, params: move_params
    end

    assert_response :conflict
    assert_select "#reschedule-alert", text: /now has both/
  end

  test "S-SCH-02.8 a move needs a time, who asked, a matching reason, and a clinic I book on; nothing is filed without them" do
    sign_in
    with_rpms do
      post path, params: move_params(start: "")
      assert_select "#reschedule-errors li", text: /choose a new time/
      post path, params: move_params(whom: "")
      assert_select "#reschedule-errors li", text: /patient or the clinic/
      post path, params: move_params(whom: "C", reason_ien: "4")
      assert_select "#reschedule-errors li", text: /Reason ien is not one/
      post path, params: move_params(resource_id: "5")
      assert_select "#reschedule-errors li", text: /not a clinic you can book on/
      post path, params: move_params(extra: "a;b")
      assert_response :unprocessable_content
    end
    assert_empty calls
  end

  test "S-SCH-02.8 a move to the same time at another clinic is refused before anything is filed" do
    sign_in
    with_rpms do
      post path, params: move_params(start: "2026-10-28T09:00")
    end

    assert_select "#reschedule-alert", text: /same time, cancel it and book again/
    assert_empty calls
  end

  test "S-SCH-02.8 a booked appointment on the clinic's day offers Move" do
    sign_in
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2", params: { date: DAY.iso8601 }
    end

    assert_select "#appointments tr[data-appointment='8'] a[href='#{path}?date=2026-10-28']", text: "Move"
  end
  test "S-SCH-02.10 and 01.7 a move to a clinic past its inactivate date is refused before anything is filed" do
    sign_in
    rules = { id: 6, display_begins: nil, schedule_on_holidays: false, max_future_days: nil, prohibit_access: false,
              inactivate_date: NEXT - 1, reactivate_date: nil }
    with_rpms(rules: rules) do
      get path, params: { date: DAY.iso8601, to: "1", on: NEXT.iso8601, whom: "PC" }
      assert_select "#no-open-times"
      post path, params: move_params
    end

    assert_response :conflict
    assert_empty calls, "nothing is booked or cancelled"
  end
end
