# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-02: a scheduler cancels an appointment. RPMS is stood in for at
# the gem boundary. Live on a built image BSDX CANCEL APPOINTMENT refuses only a
# checked-in appointment, so the rest is checked here and tested here.
class SchedulingCancelAppointmentTest < ActionDispatch::IntegrationTest
  DAY = Date.new(2026, 10, 28)

  def at(hour, min = 0) = Time.new(DAY.year, DAY.month, DAY.day, hour, min)

  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: true, modify_schedule: true, modify_appointments: true }.freeze

  # The build's CANCELLATION REASONS (#409.2): name ^ type ^ inactive.
  REASONS = { entries: [
    { ien: 4, pieces: [ "TRAVEL DIFFICULTY", "P", "" ] },
    { ien: 7, pieces: [ "CLINIC STAFFING", "C", "" ] },
    { ien: 11, pieces: [ "OTHER", "B", "" ] },
    { ien: 15, pieces: [ "RETIRED REASON", "B", "1" ] }
  ] }.freeze

  def appointment(**state)
    { id: 8, start_time: at(9), end_time: at(9, 20), patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil }.merge(state)
  end

  def sign_in(keys = "scheduling_user")
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  def with_rpms(listed: [ appointment ], cancel: ->(*) { { success: true } })
    log = (@cancels ||= [])
    blocks = [ { start_time: at(8), end_time: at(17), slots: 1 } ]
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ RESOURCE ] },
        slot_schedule: ->(**) { blocks },
        appointments: ->(**) { listed },
        cancel_appointment: ->(id, **kw) { log << kw.merge(id: id); cancel.call(id, kw) }
      },
      RpmsRpc::DdrFileman.singleton_class => { lister: ->(**) { REASONS } }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def cancels = @cancels || []

  def path = "/lakeraven-ehr/scheduling/clinics/2/appointments/8/cancel"

  def cancel_params(**changes) = { date: "2026-10-28", cancellation: { whom: "C", reason_ien: "7", remarks: "" }.merge(changes) }

  test "S-SCH-02.1 a booked appointment is cancelled by the clinic with a clinic reason" do
    sign_in
    with_rpms do
      post path, params: cancel_params(remarks: "clinic closed early")

      assert_redirected_to "/lakeraven-ehr/scheduling/clinics/2?date=2026-10-28"
      assert_equal [ { id: 8, reason: 7, type: "C", note: "clinic closed early" } ], cancels
    end
  end

  test "S-SCH-02.4 only reasons typed for who cancelled, and in use, are offered and accepted" do
    sign_in
    with_rpms do
      get path, params: { date: "2026-10-28", whom: "C" }
      assert_equal [ "CLINIC STAFFING", "OTHER" ], css_select("#cancellation-form select option").map(&:text).drop(1)

      get path, params: { date: "2026-10-28", whom: "PC" }
      assert_equal [ "TRAVEL DIFFICULTY", "OTHER" ], css_select("#cancellation-form select option").map(&:text).drop(1)

      post path, params: cancel_params(whom: "C", reason_ien: "4")
      assert_response :unprocessable_content
      post path, params: cancel_params(whom: "PC", reason_ien: "15")
      assert_response :unprocessable_content
      assert_empty cancels
    end
  end

  test "S-SCH-02.2 no say on who cancelled, or no reason, is refused and nothing changes" do
    sign_in
    with_rpms do
      post path, params: cancel_params(whom: "")
      assert_response :unprocessable_content
      assert_select "#cancellation-errors li", text: /patient or the clinic/

      post path, params: cancel_params(reason_ien: "")
      assert_select "#cancellation-errors li", text: /Reason ien is required/
      assert_empty cancels
    end
  end

  test "S-SCH-02.3 remarks shorter than 3 or longer than 160 are refused" do
    sign_in
    with_rpms do
      [ "ok", "x" * 161 ].each do |remarks|
        post path, params: cancel_params(remarks: remarks)
        assert_response :unprocessable_content, remarks.size.to_s
      end
      assert_empty cancels
    end
  end

  test "S-SCH-02.5 and 02.6 a checked-in, cancelled or no-show appointment is not cancelled" do
    sign_in
    [ appointment(checkin_time: at(8, 55)), appointment(cancelled: true), appointment(no_show: true) ].each do |state|
      with_rpms(listed: [ state ]) do
        post path, params: cancel_params
        assert_response :conflict
      end
    end
    assert_empty cancels
  end

  test "a cancelled appointment frees its place on the clinic's day" do
    sign_in
    with_rpms(listed: [ appointment(cancelled: true) ]) do
      get "/lakeraven-ehr/scheduling/clinics/2", params: { date: "2026-10-28" }
    end

    assert_select "#appointments tr[data-appointment='8'] td[data-status='cancelled']"
    assert_select "#appointments tr[data-appointment='8'] a", count: 0
    assert_select "#open-times tr[data-time='09:00'] td[data-open='1']"
  end

  test "a refusal from RPMS shows its reason" do
    sign_in
    refused = ->(*) { { success: false, error: "BSDX08: Patient already checked in; cannot cancel until checkin deleted" } }
    with_rpms(cancel: refused) do
      post path, params: cancel_params
    end

    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /already checked in/
  end
end
