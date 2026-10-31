# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-03: a scheduler checks a patient in. RPMS is stood in for at the
# gem boundary. Live on a built image BSDX CHECKIN APPOINTMENT files a second
# check-in and one with no provider where the clinic requires one, so those
# rules are checked here and tested here.
class SchedulingCheckinAppointmentTest < ActionDispatch::IntegrationTest
  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: true, modify_schedule: true, modify_appointments: true }.freeze

  def today = Date.today
  def at(hour, min = 0, day: today) = Time.utc(day.year, day.month, day.day, hour, min)

  def appointment(**state)
    { id: 8, start_time: at(0, 15), end_time: at(0, 30), patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil, checkout_time: nil }.merge(state)
  end

  def sign_in = post("/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" })

  def with_rpms(listed: [ appointment ], provider_required: "YES", checkin: ->(*) { { success: true } })
    log = (@checkins ||= [])
    setup = [ { location_ien: 3, location: "DEMO IHS CLINIC", visit_provider_required: provider_required } ]
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ RESOURCE ] },
        appointments: ->(**) { listed },
        clinic_setup: ->(*) { setup },
        checkin_appointment: ->(id, **kw) { log << kw.merge(id: id); checkin.call(id, kw) }
      },
      RpmsRpc::Practitioner.singleton_class => { search: ->(_text) { [ { ien: 206, name: "PROFILE,MD" } ] } }
    }.merge(scheduling_setup_stubs)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def checkins = @checkins || []
  def path = "/lakeraven-ehr/scheduling/clinics/2/appointments/8/checkin"
  def now_param = Time.now.strftime("%Y-%m-%dT%H:%M")
  def checkin_params(**changes) = { date: today.iso8601, checkin: { at: now_param, provider_ien: "206" }.merge(changes) }

  test "S-SCH-03.1 a patient with an appointment today is checked in, with the provider named" do
    sign_in
    with_rpms do
      post path, params: checkin_params

      assert_redirected_to "/lakeraven-ehr/scheduling/clinics/2?date=#{today.iso8601}"
      assert_equal [ 8 ], checkins.map { |c| c[:id] }
      assert_equal 206, checkins.sole[:provider]
    end
  end

  test "S-SCH-03.4 a clinic that requires a visit provider refuses a check-in without one" do
    sign_in
    with_rpms do
      post path, params: checkin_params(provider_ien: "")

      assert_response :unprocessable_content
      assert_select "#checkin-errors li", text: /Provider ien is required at this clinic/
    end
    with_rpms(provider_required: "NO") do
      post path, params: checkin_params(provider_ien: "")
      assert_response :redirect
    end
    assert_equal 1, checkins.size
  end

  test "a clinic with no setup row counts as requiring a provider" do
    sign_in
    with_rpms(provider_required: nil) do
      post path, params: checkin_params(provider_ien: "")
      assert_response :unprocessable_content
    end
  end

  test "S-SCH-03.3 a check-in on another day than the appointment's, or in the future, is refused" do
    sign_in
    with_rpms do
      post path, params: checkin_params(at: (today - 1).strftime("%Y-%m-%dT09:00"))
      assert_select "#checkin-errors li", text: /must be on the appointment's day/

      post path, params: checkin_params(at: (Time.now + 3600).strftime("%Y-%m-%dT%H:%M"))
      assert_select "#checkin-errors li", text: /cannot be in the future/
      assert_empty checkins
    end
  end

  test "S-SCH-03.7 an appointment checked in, checked out, cancelled or no-show is not checked in" do
    sign_in
    [ appointment(checkin_time: at(0, 10)), appointment(checkout_time: at(0, 40)), appointment(cancelled: true), appointment(no_show: true) ].each do |state|
      with_rpms(listed: [ state ]) do
        post path, params: checkin_params
        assert_response :conflict
      end
    end
    assert_empty checkins
  end

  test "the provider is found by name" do
    sign_in
    with_rpms do
      get path, params: { date: today.iso8601, provider_search: "PROF" }
    end

    assert_select "#checkin-form label[data-provider='206']", text: /PROFILE,MD/
  end

  test "a refusal from RPMS shows its reason" do
    sign_in
    with_rpms(checkin: ->(*) { { success: false, error: "BSDX25: Patient has a temporary chart number" } }) do
      post path, params: checkin_params
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /temporary chart number/
  end
end
