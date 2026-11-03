# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-06: a clerk books and checks in a patient who came without an
# appointment, in one step. RPMS is stood in for at the gem boundary: the
# walk-in is BSDX ADD NEW APPOINTMENT with the access type "WALKIN" at the
# current slot, then BSDX CHECKIN APPOINTMENT.
class SchedulingWalkInTest < ActionDispatch::IntegrationTest
  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: false, modify_schedule: true, modify_appointments: true }.freeze
  LOOK_ONLY = RESOURCE.merge(id: 5, name: "DEMO DENTAL", hospital_location_id: 9, modify_appointments: false).freeze

  STOPS = { entries: [
    { ien: 1, pieces: [ "MEDICINE", "01", "" ] },
    { ien: 21, pieces: [ "DENTAL", "56", "" ] },
    { ien: 30, pieces: [ "RETIRED STOP", "99", "3200101" ] }
  ] }.freeze

  def today = Date.today
  def now_param = Time.now.strftime("%Y-%m-%dT%H:%M")

  def sign_in = post("/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" })

  # slots: places in today's all-day block; listed: today's appointments
  # before any write; after: what RPMS lists once the walk-in is booked.
  def with_rpms(slots: 1, listed: [], after: nil, several_stops: "NO", provider_required: "YES", rules: nil,
                add: nil, checkin: nil, cancel: nil)
    @calls = []
    calls = @calls
    add ||= ->(**) { { success: true, appointment_id: 40 } }
    checkin ||= ->(*) { { success: true } }
    cancel ||= ->(*) { { success: true } }
    setup = [ { location_ien: 3, location: "DEMO IHS CLINIC", visit_provider_required: provider_required, multiple_clinic_codes: several_stops } ]
    day = Date.today
    block = { start_time: Time.new(day.year, day.month, day.day, 0, 0), end_time: Time.new(day.year, day.month, day.day, 23, 59), slots: slots }
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ RESOURCE, LOOK_ONLY ] },
        slot_schedule: ->(**) { [ block ] },
        appointments: ->(**) { calls.any? { |c| c.first == :add } && after ? after : listed },
        clinic_setup: ->(*) { setup },
        add_appointment: ->(**kw) { calls << [ :add, kw ]; add.call(**kw) },
        checkin_appointment: ->(id, **kw) { calls << [ :checkin, kw.merge(id: id) ]; checkin.call(id, kw) },
        cancel_appointment: ->(id, **kw) { calls << [ :cancel, kw.merge(id: id) ]; cancel.call(id, kw) }
      },
      RpmsRpc::Patient.singleton_class => {
        search: ->(_text) { [ { dfn: 3, name: "MOUSE,MICKEY M" } ] },
        brief_header: ->(dfn) { dfn.to_i == 3 ? { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), mrn: "1001" } : nil }
      },
      RpmsRpc::Practitioner.singleton_class => { search: ->(_text, key: nil) { [ { ien: 206, name: "PROFILE,MD" } ] } },
      RpmsRpc::DdrFileman.singleton_class => { lister: ->(**) { STOPS } }
    }.merge(scheduling_setup_stubs(rules: rules))
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def calls = @calls || []
  def path = "/lakeraven-ehr/scheduling/clinics/2/walk_ins"
  def walk_in_params(**changes) = { walk_in: { patient_dfn: "3", at: now_param, provider_ien: "206", stop_ien: "" }.merge(changes) }

  def slot_now
    t = Time.now
    Time.new(t.year, t.month, t.day, t.hour, t.min - (t.min % 15))
  end

  test "S-SCH-06.1 a walk-in is booked at the current slot as a walk-in, then checked in by me with the provider" do
    sign_in
    with_rpms do
      post path, params: walk_in_params

      assert_redirected_to "/lakeraven-ehr/scheduling/clinics/2?date=#{today.iso8601}"
      assert_equal %i[add checkin], calls.map(&:first), "booked, then checked in"
      added = calls.first.last
      assert_equal [ 3, "DEMO IHS CLINIC", slot_now, slot_now + 900, 15, "WALKIN" ],
                   added.values_at(:patient_dfn, :resource, :start_time, :end_time, :length_minutes, :access_type)
      checked = calls.last.last
      assert_equal [ 40, 206, nil ], checked.values_at(:id, :provider, :clinic_code)
    end
  end

  test "S-SCH-06.2 a full current slot is refused and nothing is filed" do
    sign_in
    busy = { id: 9, start_time: slot_now, end_time: slot_now + 900, patient_dfn: 7, patient_name: "DUCK,DONALD", cancelled: false }
    with_rpms(listed: [ busy ]) do
      post path, params: walk_in_params
    end

    assert_response :conflict
    assert_select "#walk-in-alert", text: /no place at this time/
    assert_empty calls
  end

  test "S-SCH-06.2 and 01.7 a clinic past its inactivate date takes no walk-in" do
    sign_in
    rules = { id: 3, display_begins: nil, schedule_on_holidays: false, max_future_days: nil, prohibit_access: false,
              inactivate_date: today - 1, reactivate_date: nil }
    with_rpms(rules: rules) do
      post path, params: walk_in_params
    end

    assert_response :conflict
    assert_empty calls
  end

  test "S-SCH-06.3 a missing provider, stop or check-in time is refused and neither an appointment nor a visit is filed" do
    sign_in
    with_rpms(several_stops: "YES") do
      get "#{path}/new"
      assert_equal [ "MEDICINE (01)", "DENTAL (56)" ], css_select("#walk-in-form select option").map(&:text).drop(1), "only stops in use"

      post path, params: walk_in_params(provider_ien: "", stop_ien: "21")
      assert_select "#walk-in-errors li", text: /Provider ien is required at this clinic/
      post path, params: walk_in_params(stop_ien: "")
      assert_select "#walk-in-errors li", text: /uses several/
      post path, params: walk_in_params(at: "", stop_ien: "21")
      assert_select "#walk-in-errors li", text: /At is required/
      post path, params: walk_in_params(patient_dfn: "", stop_ien: "21")
      assert_select "#walk-in-errors li", text: /choose a patient/
      post path, params: walk_in_params(at: "#{(today - 1).iso8601}T09:00", stop_ien: "21")
      assert_select "#walk-in-errors li", text: /must be today/
      assert_response :unprocessable_content
    end
    assert_empty calls
  end

  test "S-SCH-06.3 a clinic that uses several stops files the one chosen" do
    sign_in
    with_rpms(several_stops: "YES") do
      post path, params: walk_in_params(stop_ien: "21")
    end

    assert_equal 21, calls.last.last[:clinic_code]
  end

  test "S-SCH-06.3 when RPMS refuses the check-in, the walk-in booking is cancelled again" do
    sign_in
    refused = ->(*) { { success: false, error: "BSDX25: Patient has a temporary chart number" } }
    with_rpms(checkin: refused) do
      post path, params: walk_in_params
    end

    assert_response :unprocessable_content
    assert_equal %i[add checkin cancel], calls.map(&:first)
    assert_equal 40, calls.last.last[:id]
    assert_select "#walk-in-alert", text: /temporary chart number.*not booked either/m
  end

  test "S-SCH-06.1 the patient search posts, so the name typed is not in the URL" do
    sign_in
    with_rpms do
      post "#{path}/find", params: { q: "MOUSE", walk_in: { at: now_param } }
    end

    assert_response :ok
    assert_select "#walk-in-form label[data-patient='3']", text: /MOUSE,MICKEY M, health record number 1001/
    assert_select "#walk-in-form input[type=submit][formaction='#{path}/find'][formmethod=post]", minimum: 1
    assert_empty calls
  end

  test "S-SCH-06.1 today's day view offers a walk-in; another day and a clinic I only see do not" do
    sign_in
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2", params: { date: today.iso8601 }
      assert_select "a#walk-in[href='#{path}/new']"
      get "/lakeraven-ehr/scheduling/clinics/2", params: { date: (today + 1).iso8601 }
      assert_select "a#walk-in", count: 0
      get "/lakeraven-ehr/scheduling/clinics/5", params: { date: today.iso8601 }
      assert_select "a#walk-in", count: 0
      get "/lakeraven-ehr/scheduling/clinics/5/walk_ins/new"
      assert_response :forbidden
    end
  end
end
