# frozen_string_literal: true

require "test_helper"

# The clinic's "today" and "now" are the site's clock, which RPMS keeps
# (ORWU DT "NOW"), not the app host's UTC clock (#1114). On a Sunday evening
# Pacific the host's UTC date is already Monday: the clinic's day must still
# offer Check in for Sunday's appointments, and the check-in, check-out and
# walk-in forms must fill in the site's time. RPMS is stood in for at the gem
# boundary; its clock is what RpmsRpc::Orwu.fileman_datetime("NOW") answers.
class SchedulingSiteTimeTest < ActionDispatch::IntegrationTest
  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: true, modify_schedule: true, modify_appointments: true }.freeze

  # Sunday Nov 8, 2026, 20:10 Pacific (PST, UTC-8) is Monday 04:10 UTC.
  SITE_NOW = "3261108.201"
  HOST_NOW = Time.utc(2026, 11, 9, 4, 10)
  SUNDAY = Date.new(2026, 11, 8)

  setup do
    # The app host runs in UTC, as the demo's does; BSDX times are read in
    # the process's zone (WallClock), so they are built in UTC here too.
    @tz = ENV["TZ"]
    ENV["TZ"] = "UTC"
    RpmsStandIn.answer(RpmsRpc::Orwu, :fileman_datetime, "NOW", with: SITE_NOW)
    Lakeraven::EHR::SiteTime.reader = nil if defined?(Lakeraven::EHR::SiteTime)
    travel_to HOST_NOW
  end

  teardown do
    travel_back
    Lakeraven::EHR::SiteTime.reader = -> { Time.now } if defined?(Lakeraven::EHR::SiteTime)
    ENV["TZ"] = @tz
  end

  def sunday_at(hour, min = 0) = Time.new(SUNDAY.year, SUNDAY.month, SUNDAY.day, hour, min)

  def appointment(**state)
    { id: 8, start_time: sunday_at(19), end_time: sunday_at(19, 15), patient_dfn: 3, patient_name: "MOUSE,MICKEY M",
      cancelled: false, no_show: false, checkin_time: nil, checkout_time: nil }.merge(state)
  end

  def sign_in = post("/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" })

  def with_rpms(listed: [ appointment ])
    log = (@writes ||= [])
    block = { start_time: sunday_at(0), end_time: sunday_at(23, 59), slots: 4 }
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { [ RESOURCE ] },
        slot_schedule: ->(**) { [ block ] },
        appointments: ->(**) { listed },
        clinic_setup: ->(*) { [ { location_ien: 3, location: "DEMO IHS CLINIC", visit_provider_required: "NO", multiple_clinic_codes: "NO" } ] },
        add_appointment: ->(**kw) { log << [ :add, kw ]; { success: true, appointment_id: 40 } },
        checkin_appointment: ->(id, **kw) { log << [ :checkin, kw.merge(id: id) ]; { success: true } }
      },
      RpmsRpc::Patient.singleton_class => {
        search: ->(_text) { [ { dfn: 3, name: "MOUSE,MICKEY M" } ] },
        brief_header: ->(dfn) { dfn.to_i == 3 ? { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), mrn: "1001" } : nil }
      },
      RpmsRpc::Practitioner.singleton_class => { search: ->(_text, key: nil) { [] } }
    }.merge(scheduling_setup_stubs)
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def writes = @writes || []
  def clinic = "/lakeraven-ehr/scheduling/clinics/2"

  test "S-SCH-03.1 on a Sunday evening at the site, the clinic's Sunday offers Check in though the host's UTC date is Monday" do
    sign_in
    with_rpms { get clinic, params: { date: SUNDAY.iso8601 } }

    assert_response :ok
    assert_select "tr[data-appointment='8'] [data-actions] a", text: "Check in"
  end

  test "S-SCH-03.1 the clinic's day opens on the site's today" do
    sign_in
    with_rpms { get clinic }

    assert_response :ok
    assert_select "tr[data-appointment='8'] [data-actions] a", text: "Check in"
  end

  test "S-SCH-03.1 the check-in form fills in the site's time, and RPMS is sent that time" do
    sign_in
    with_rpms do
      get "#{clinic}/appointments/8/checkin", params: { date: SUNDAY.iso8601 }
      assert_select "input[name='checkin[at]'][value=?]", "2026-11-08T20:10"

      post "#{clinic}/appointments/8/checkin", params: { date: SUNDAY.iso8601, checkin: { at: "2026-11-08T20:10" } }
    end

    assert_redirected_to "#{clinic}?date=#{SUNDAY.iso8601}"
    assert_equal sunday_at(20, 10), writes.sole.last[:checkin_time]
  end

  test "S-SCH-07.1 the check-out form fills in the site's time" do
    sign_in
    with_rpms(listed: [ appointment(checkin_time: sunday_at(19, 5)) ]) do
      get "#{clinic}/appointments/8/checkout", params: { date: SUNDAY.iso8601 }
    end

    assert_select "input[name='checkout[at]'][value=?]", "2026-11-08T20:10"
  end

  test "S-SCH-06.1 a walk-in on a Sunday evening at the site is booked on Sunday at the site's time" do
    sign_in
    with_rpms(listed: []) do
      get "#{clinic}/walk_ins/new"
      assert_select "input[name='walk_in[at]'][value=?]", "2026-11-08T20:10"

      post "#{clinic}/walk_ins", params: { walk_in: { patient_dfn: "3", at: "2026-11-08T20:10" } }
    end

    assert_redirected_to "#{clinic}?date=#{SUNDAY.iso8601}"
    assert_equal sunday_at(20, 0), writes.first.last[:start_time]
  end
end
