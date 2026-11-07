# frozen_string_literal: true

require "test_helper"

# rpms-ux S-REG-03.2: a patient whose eligibility has lapsed is flagged at
# check-in, before the visit is created. Whether coverage is in force today
# is AG's own answer (RpmsRpc::Coverage.on_file), stood in for here.
class SchedulingCheckinCoverageTest < ActionDispatch::IntegrationTest
  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: true, modify_schedule: true, modify_appointments: true }.freeze

  def today = Date.today

  def appointment
    start = Time.utc(today.year, today.month, today.day, 0, 15)
    { id: 8, start_time: start, end_time: start + 900, patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil, checkout_time: nil }
  end

  def medicaid(active:, ends_on:)
    { medicaid: [ { record_ien: "4", payer: "MEDICAID", number: "ZZ1", state: "WASHINGTON", active: active,
                    eligibility: [ { ien: "1", starts_on: Date.new(2024, 1, 1), ends_on: ends_on, coverage: "" } ] } ],
      medicare: [], private: [] }
  end

  def sign_in(keys) = post("/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: keys })

  def with_rpms(on_file)
    listed = [ appointment ]
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ RESOURCE ] },
        appointments: ->(**) { listed },
        clinic_setup: ->(*) { [ { location_ien: 3, location: "DEMO IHS CLINIC", visit_provider_required: "NO" } ] }
      },
      RpmsRpc::Coverage.singleton_class => { on_file: on_file.is_a?(Proc) ? on_file : ->(_dfn) { on_file } }
    }.merge(scheduling_setup_stubs)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def path = "/lakeraven-ehr/scheduling/clinics/2/appointments/8/checkin?date=#{today.iso8601}"

  test "S-REG-03.2 a patient whose eligibility has lapsed is flagged before the check-in is sent" do
    sign_in("scheduling_user,registration_menu")
    with_rpms(medicaid(active: false, ends_on: Date.new(2025, 6, 30))) { get path }

    assert_response :ok
    assert_select "#coverage-lapsed", text: /None of this patient's coverage is in force today/
    assert_select "#coverage-lapsed a[href='/lakeraven-ehr/registration/patients/3/coverage']"
    assert_select "#checkin-form"
  end

  test "S-REG-03.2 coverage in force today raises no flag" do
    sign_in("scheduling_user")
    with_rpms(medicaid(active: true, ends_on: nil)) { get path }

    assert_select "#coverage-lapsed", 0
    assert_select "#coverage-unchecked", 0
    assert_select "#coverage-none", 0
  end

  test "with no coverage on file the clerk is told so" do
    sign_in("scheduling_user")
    with_rpms({ medicaid: [], medicare: [], private: [] }) { get path }

    assert_select "#coverage-none"
  end

  test "a scheduler RPMS will not let read coverage is told it was not checked, never that it is fine" do
    sign_in("scheduling_user")
    refuse = ->(_dfn) { raise RpmsRpc::Client::RpcRefusedError, "4 Access denied for remote procedure: AGG BUILD WINDOW MANY" }
    with_rpms(refuse) { get path }

    assert_response :ok
    assert_select "#coverage-unchecked"
    assert_select "#coverage-lapsed", 0
  end
end
