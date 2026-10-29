# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-01: a scheduler books a patient into an open time. RPMS is stood
# in for at the gem boundary with the shapes a live rpms-ydb e9b78c8 build
# answered: an 08:00-17:00 block of 4 slots on a 15-minute grid.
class SchedulingBookAppointmentTest < ActionDispatch::IntegrationTest
  DAY = Date.new(2026, 10, 28)

  def at(hour, min = 0) = Time.new(DAY.year, DAY.month, DAY.day, hour, min)

  RESOURCES = [
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true },
    { id: 5, name: "LOOK ONLY CLINIC", inactive: false, time_scale: 15, hospital_location_id: 8,
      view: true, overbook: false, modify_schedule: false, modify_appointments: false }
  ].freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  # Stands in for RpmsRpc::Scheduling and the patient selection; records bookings.
  def with_rpms(appointments: [], book: ->(_args) { { success: true, appointment_id: 9 } })
    blocks = [ { start_time: at(0, 1), end_time: at(8), slots: 0 }, { start_time: at(8), end_time: at(17), slots: 4 } ]
    log = (@booked ||= [])
    sched = RpmsRpc::Scheduling.singleton_class
    patient = RpmsRpc::Patient.singleton_class
    stubs = {
      sched => {
        resources: ->(*) { RESOURCES },
        slot_schedule: ->(**) { blocks },
        appointments: ->(**) { appointments },
        add_appointment: ->(**args) { log << args; book.call(args) }
      },
      patient => {
        search: ->(_text) { [ { dfn: 3, name: "MOUSE,MICKEY M" } ] },
        brief_header: ->(dfn) { dfn.to_i == 3 ? { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), mrn: "1001" } : nil }
      }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def booked = @booked || []

  def book_params(**changes)
    { booking: { patient_dfn: "3", start: "2026-10-28T09:00", length: "20", note: "" }.merge(changes) }
  end

  test "S-SCH-01.12 without SDZMENU or SDZSUP, scheduling is closed" do
    sign_in("registration_menu")
    get "/lakeraven-ehr/scheduling"

    assert_response :forbidden
  end

  test "the clinic's day shows its open times on the slot grid, with places left" do
    sign_in("scheduling_user")
    with_rpms(appointments: [ { id: 1, start_time: at(9), end_time: at(9, 20), patient_dfn: 3, patient_name: "MOUSE,MICKEY M", cancelled: false, no_show: false, checkin_time: nil } ]) do
      get "/lakeraven-ehr/scheduling/clinics/2", params: { date: "2026-10-28" }
    end

    assert_response :ok
    assert_select "#open-times tr[data-time='08:00'] td[data-open='4']"
    assert_select "#open-times tr[data-time='09:00'] td[data-open='3']"
    assert_select "#appointments tr[data-patient='3'] td", text: "MOUSE,MICKEY M"
  end

  test "S-SCH-01.1 a booking in an open time is filed on the clinic's resource" do
    sign_in("scheduling_user")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/2/appointments", params: book_params

      assert_redirected_to "/lakeraven-ehr/scheduling/clinics/2?date=2026-10-28"
      assert_equal [ { patient_dfn: 3, resource: "DEMO IHS CLINIC", start_time: at(9), end_time: at(9, 20), length_minutes: 20, note: nil } ], booked
    end
  end

  test "S-SCH-01.2 a full time is refused here, and nothing is filed" do
    sign_in("scheduling_user")
    four = Array.new(4) { |i| { id: 20 + i, start_time: at(10), end_time: at(10, 20), patient_dfn: 10 + i, patient_name: "P", cancelled: false, no_show: false, checkin_time: nil } }
    with_rpms(appointments: four) do
      post "/lakeraven-ehr/scheduling/clinics/2/appointments", params: book_params(start: "2026-10-28T10:00")

      assert_response :conflict
      assert_select "[role='alert']", text: /full or outside the clinic's open hours/
      assert_empty booked
    end
  end

  test "a time outside every open block is refused" do
    sign_in("scheduling_user")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/2/appointments", params: book_params(start: "2026-10-28T07:30")

      assert_response :conflict
      assert_empty booked
    end
  end

  test "S-SCH-01.3 a booking with no patient or no length names it, and nothing is filed" do
    sign_in("scheduling_user")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/2/appointments", params: book_params(patient_dfn: "", length: "")

      assert_response :unprocessable_content
      assert_select "#booking-errors li", text: /Patient dfn is required: choose a patient/
      assert_select "#booking-errors li", text: /Length/
      assert_empty booked
    end
  end

  test "S-SCH-01.4 a note too short or with a semicolon or colon is refused" do
    sign_in("scheduling_user")
    with_rpms do
      [ "x", "see dr; today", "re: follow up", "a" * 151 ].each do |note|
        post "/lakeraven-ehr/scheduling/clinics/2/appointments", params: book_params(note: note)
        assert_response :unprocessable_content, note
      end
      assert_empty booked
    end
  end

  test "S-SCH-01.5 a refusal from RPMS shows its reason" do
    sign_in("scheduling_user")
    refusal = ->(_args) { { success: false, error: "BSDX07 Error: Unable to make appointment. Patient 3 already has appt at 3261028.09" } }
    with_rpms(book: refusal) do
      post "/lakeraven-ehr/scheduling/clinics/2/appointments", params: book_params
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /already has appt/
  end

  test "S-SCH-01.13 a resource the user may only look at can be seen, not booked" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/5", params: { date: "2026-10-28" }
      assert_response :ok
      assert_select "#open-times a", count: 0

      post "/lakeraven-ehr/scheduling/clinics/5/appointments", params: book_params
      assert_response :forbidden
      assert_empty booked
    end
  end

  test "SDZSUP books on a resource whose rights do not let the user modify it" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/clinics/5/appointments", params: book_params
    end

    assert_response :redirect
    assert_equal "LOOK ONLY CLINIC", booked.sole[:resource]
  end

  test "the scheduler finds the patient by name with VueCentric's selection" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2/appointments/new", params: { start: "2026-10-28T09:00", q: "MOU" }
    end

    assert_response :ok
    assert_select "#booking-form label[data-patient='3']", text: /MOUSE,MICKEY M,\s+HRN 1001,\s+born Feb 14, 1910/
  end
end
