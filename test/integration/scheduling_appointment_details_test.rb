# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-09: a scheduler corrects an appointment without rebooking it.
# RPMS is stood in for at the gem boundary: BSDX EDIT APPOINTMENT
# (Scheduling.edit_appointment), BSDX CLINIC VAR APPT (variable_length?), and
# the clinic's note and the patient's remarks (SchedulingSetup.set_clinic_note,
# set_cancellation_remarks).
class SchedulingAppointmentDetailsTest < ActionDispatch::IntegrationTest
  DAY = Date.new(2026, 10, 28)

  def at(hour, min = 0) = Time.new(DAY.year, DAY.month, DAY.day, hour, min)

  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: false, modify_schedule: false, modify_appointments: true }.freeze

  def appointment(**state)
    { id: 8, start_time: at(9), end_time: at(9, 15), patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil, checkout_time: nil, note: "bring meds " }.merge(state)
  end

  def sign_in = post("/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" })

  def with_rpms(listed: appointment, variable: true, edit: { success: true }, clinic_note: { success: true }, remarks: { success: true })
    @calls = []
    calls = @calls
    block = { start_time: at(8), end_time: at(17), slots: 1 }
    setup = scheduling_setup_stubs
    setup[RpmsRpc::SchedulingSetup.singleton_class].merge!(
      set_clinic_note: ->(**kw) { calls << [ :clinic_note, kw ]; clinic_note },
      set_cancellation_remarks: ->(**kw) { calls << [ :remarks, kw ]; remarks }
    )
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ RESOURCE ] },
        slot_schedule: ->(**) { [ block ] },
        appointments: ->(**) { [ listed ] },
        variable_length?: ->(_clinic) { variable },
        edit_appointment: ->(id, **kw) { calls << [ :edit, kw.merge(id: id) ]; edit }
      }
    }.merge(setup)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def calls = @calls || []
  def path = "/lakeraven-ehr/scheduling/clinics/2/appointments/8/details"
  def save(**details) = post(path, params: { date: DAY.iso8601, details: details })

  test "S-SCH-09.1 a new note is filed on the appointment and on the clinic, and nothing else changes" do
    sign_in
    with_rpms do
      save(note: "bring meds and glasses", length: "15")
    end

    assert_redirected_to "/lakeraven-ehr/scheduling/clinics/2?date=2026-10-28"
    assert_equal [ :edit, { note: "bring meds and glasses", length_minutes: nil, id: 8 } ], calls.first
    assert_equal [ :clinic_note, { hospital_location_id: 3, start_time: at(9), patient_dfn: 3, note: "bring meds and glasses" } ], calls.last
  end

  test "S-SCH-09.2 a note shorter than 2 or longer than 150, or with a semicolon or a colon, is refused" do
    sign_in
    with_rpms do
      [ "x", "y" * 151, "a;b", "at 9:00" ].each do |note|
        save(note: note)
        assert_response :unprocessable_content, note
      end
    end
    assert_empty calls
  end

  test "S-SCH-09.3 a cancelled or no-show appointment's remarks are filed on the patient" do
    sign_in
    [ appointment(cancelled: true), appointment(no_show: true) ].each do |closed|
      with_rpms(listed: closed) do
        get path, params: { date: DAY.iso8601 }
        assert_select "#details-form input[name='details[remarks]']"
        assert_select "#details-form input[name='details[note]']", count: 0

        save(remarks: "ok")
        assert_response :unprocessable_content
        save(remarks: "patient called back")
        assert_redirected_to "/lakeraven-ehr/scheduling/clinics/2?date=2026-10-28"
        assert_equal [ [ :remarks, { patient_dfn: 3, start_time: at(9), remarks: "patient called back" } ] ], calls
      end
    end
  end

  test "S-SCH-09.4 at a clinic that allows variable lengths, the length changes and the start stays" do
    sign_in
    with_rpms do
      get path, params: { date: DAY.iso8601 }
      assert_select "#details-form input[name='details[length]'][value='15']"

      save(note: "bring meds", length: "30")
    end

    assert_equal [ :edit, { note: "bring meds", length_minutes: 30, id: 8 } ], calls.first
    assert_equal [ :edit ], calls.map(&:first), "an unchanged note is not filed again on the clinic"
  end

  test "S-SCH-09.4 a clinic that does not allow variable lengths offers no length, and a length sent anyway is ignored" do
    sign_in
    with_rpms(variable: false) do
      get path, params: { date: DAY.iso8601 }
      assert_select "#details-form input[name='details[length]']", count: 0

      save(note: "bring meds", length: "30")
    end

    assert_nil calls.first.last[:length_minutes]
  end

  test "S-SCH-09 a checked-in appointment is not changed here" do
    sign_in
    with_rpms(listed: appointment(checkin_time: at(8, 55))) do
      get path, params: { date: DAY.iso8601 }
    end

    assert_response :conflict
  end

  test "S-SCH-09.1 when RPMS refuses, its reason is shown; when the clinic copy fails, the scheduler is told to save again" do
    sign_in
    with_rpms(edit: { success: false, error: "BSDX26: Invalid Appointment ID" }) { save(note: "new note") }
    assert_select "#details-alert", text: /Invalid Appointment ID/

    with_rpms(clinic_note: { success: false, error: "the clinic holds no appointment" }) { save(note: "new note") }
    assert_response :conflict
    assert_select "#details-alert", text: /did not file it on the clinic.*Save it again/m
  end

  test "S-SCH-09 the clinic's day offers Change details on a booked appointment and Change remarks on a cancelled one" do
    sign_in
    with_rpms { get "/lakeraven-ehr/scheduling/clinics/2", params: { date: DAY.iso8601 } }
    assert_select "#appointments tr[data-appointment='8'] a[data-action-name='details']", text: "Change details"

    with_rpms(listed: appointment(cancelled: true)) { get "/lakeraven-ehr/scheduling/clinics/2", params: { date: DAY.iso8601 } }
    assert_select "#appointments tr[data-appointment='8'] a[data-action-name='remarks']", text: "Change remarks"
  end
end
