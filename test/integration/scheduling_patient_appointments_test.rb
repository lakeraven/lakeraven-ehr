# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-05.6 and 05.7: a scheduler opens one patient's appointments
# across clinics. RPMS is stood in for at the gem boundary with the shape
# Scheduling.patient_appointments (BSDX PATIENT APPT DISPLAY) returns.
class SchedulingPatientAppointmentsTest < ActionDispatch::IntegrationTest
  TODAY = Date.today

  def at(day, hour, min = 0) = Time.new(day.year, day.month, day.day, hour, min)

  RESOURCES = [
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true }
  ].freeze

  def appointments
    [
      { start_time: at(TODAY - 9, 9), clinic: "DEMO IHS CLINIC", resource_id: 2, type: "SCHED", status: "checked out",
        made_by: "PROFILE,SCHED", made_at: at(TODAY - 20, 8), note: nil },
      { start_time: at(TODAY, 13, 15), clinic: "DEMO IHS CLINIC", resource_id: 2, type: "WALK-IN", status: "checked in",
        made_by: "PROFILE,REG", made_at: at(TODAY, 8), note: nil },
      { start_time: at(TODAY + 12, 10, 30), clinic: "OTHER CLINIC", resource_id: 9, type: "SCHED", status: "scheduled",
        made_by: "PROFILE,SCHED", made_at: at(TODAY - 1, 16), note: "bring records" }
    ]
  end

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  def with_rpms(listed = appointments)
    sched = RpmsRpc::Scheduling.singleton_class
    patient = RpmsRpc::Patient.singleton_class
    stubs = {
      sched => { resources: ->(*) { RESOURCES }, patient_appointments: ->(dfn) { dfn.to_i == 3 ? listed : [] } },
      patient => { brief_header: ->(dfn) { dfn.to_i == 3 ? { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), mrn: "1001" } : nil } }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def rows = css_select("#patient-appointments tr[data-start]")

  test "S-SCH-05.6 each appointment is listed with its clinic, type, status and who made it when" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/patients/3/appointments"

      assert_response :ok
      assert_select "h1", text: /MOUSE,MICKEY M/
      assert_equal 3, rows.size
      walk_in = rows.find { |tr| tr["data-status"] == "checked in" }
      assert_match(/DEMO IHS CLINIC/, walk_in.text)
      assert_match(/WALK-IN/, walk_in.text)
      assert_match(/PROFILE,REG/, walk_in.text)
      assert_match(/bring records/, rows.find { |tr| tr["data-status"] == "scheduled" }.text)
    end
  end

  test "S-SCH-05.6 an appointment in a clinic of mine links to its day there; another clinic's does not" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/patients/3/appointments"

      mine = rows.find { |tr| tr["data-status"] == "checked in" }
      assert_equal "/lakeraven-ehr/scheduling/clinics/2?date=#{TODAY.iso8601}", mine.at_css("a[data-clinic-day]")["href"]
      other = rows.find { |tr| tr["data-status"] == "scheduled" }
      assert_nil other.at_css("a[data-clinic-day]")
    end
  end

  test "S-SCH-05.7 the list can be kept to today, the past or the future, and says when there are none" do
    sign_in("scheduling_user")
    with_rpms do
      { "today" => "checked in", "past" => "checked out", "future" => "scheduled" }.each do |w, status|
        get "/lakeraven-ehr/scheduling/patients/3/appointments", params: { when: w }
        assert_equal [ status ], rows.map { |tr| tr["data-status"] }, w
      end
    end
    with_rpms([]) do
      get "/lakeraven-ehr/scheduling/patients/3/appointments", params: { when: "future" }
      assert_select "#no-appointments"
    end
  end

  test "without a scheduling key the list is closed" do
    sign_in("registration_menu")
    get "/lakeraven-ehr/scheduling/patients/3/appointments"

    assert_response :forbidden
  end
  test "a patient on a clinic's day links to their appointments" do
    sign_in("scheduling_user")
    day = [ { id: 7, start_time: at(TODAY, 9), end_time: at(TODAY, 9, 15), checkin_time: nil, patient_dfn: 3,
              patient_name: "MOUSE,MICKEY M", cancelled: false, no_show: false, checkout_time: nil } ]
    stubs = { RpmsRpc::Scheduling.singleton_class => { resources: ->(*) { RESOURCES }, slot_schedule: ->(**) { [] }, appointments: ->(**) { day } } }
      .merge(scheduling_setup_stubs)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    get "/lakeraven-ehr/scheduling/clinics/2", params: { date: TODAY.iso8601 }

    assert_select "#appointments tr[data-patient='3'] a[data-patient-appointments][href='/lakeraven-ehr/scheduling/patients/3/appointments']"
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end
end
