# frozen_string_literal: true

require "test_helper"

# #616 within #565: inspect the site's RPMS HOLIDAY calendar and the selected
# clinic's scheduling policy. Synthetic gem replies, not live parity evidence.
class SchedulingClinicHolidaysTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  RESOURCE = { id: 7, name: "DEMO CLINIC", inactive: false, time_scale: 30,
               hospital_location_id: 23, view: true, overbook: false,
               modify_schedule: false, modify_appointments: false }.freeze
  HOLIDAYS = [ { date: Date.new(2027, 12, 25), name: "Winter holiday" },
               { date: Date.new(2027, 1, 1), name: "New year" } ].freeze
  PATH = "/lakeraven-ehr/scheduling/clinics/7/holidays"

  def sign_in(keys = "scheduling_user")
    post "/lakeraven-ehr/test_session", params: {
      duz: "208", user_type: "user", user_name: "DEMO,SCHEDULER", security_keys: keys
    }
  end

  def with_calendar(holidays: HOLIDAYS, rules: { schedule_on_holidays: false }, resources: [ RESOURCE ], holiday_error: nil, rules_error: nil)
    @holiday_reads = []
    @rule_reads = []
    @writes = []
    holiday_reads, rule_reads, writes = @holiday_reads, @rule_reads, @writes
    stubs = {
      RpmsRpc::Scheduling.singleton_class => { resources: ->(*) { resources } },
      RpmsRpc::SchedulingSetup.singleton_class => {
        holidays: ->(**args) { holiday_reads << args; raise holiday_error if holiday_error; holidays },
        clinic_rules: ->(id) { rule_reads << id; raise rules_error if rules_error; rules }
      },
      RpmsRpc::DdrFileman.singleton_class => { filer: ->(**args) { writes << args; { success: true } } }
    }
    stubs.each { |klass, methods| methods.each_key { |method| klass.alias_method(:"__holiday_#{method}", method) } }
    stubs.each { |klass, methods| methods.each { |method, body| klass.define_method(method, &body) } }
    yield
  ensure
    stubs.each do |klass, methods|
      methods.each_key { |method| klass.alias_method(method, :"__holiday_#{method}"); klass.remove_method(:"__holiday_#{method}") }
    end
  end

  test "a visible-clinic scheduler sees site-wide holidays sorted by date and the clinic policy" do
    sign_in
    with_calendar do
      get PATH, params: { year: "2027" }

      assert_response :success
      assert_equal %w[2027-01-01 2027-12-25], css_select("#clinic-holidays tbody time").map { |time| time["datetime"] }
      assert_select "#clinic-holidays tbody tr", count: 2
      assert_match(/site-wide|global/i, response.body)
      assert_select "#clinic-holiday-policy", text: /does not schedule|No/i
      assert_select "form[method='get'] [name='year'][value='2027']", count: 1
      assert_select "form[method='post'][action*='/scheduling/clinics/']", count: 0
      assert_select "input[type='checkbox']", count: 0
    end
    assert_equal [ { start_date: Date.new(2027, 1, 1), end_date: Date.new(2027, 12, 31) } ], @holiday_reads
    assert_equal [ 23 ], @rule_reads
    assert_empty @writes
  end

  test "a clinic that schedules on holidays says so without removing those dates" do
    sign_in
    with_calendar(rules: { schedule_on_holidays: true }) do
      get PATH, params: { year: "2027" }

      assert_response :success
      assert_select "#clinic-holiday-policy", text: /schedules on holidays|Yes/i
      assert_select "#clinic-holidays tbody tr", count: 2
    end
    assert_empty @writes
  end

  test "the omitted year defaults to the site's year rather than the process clock" do
    sign_in
    StubHelpers.with_stub(Lakeraven::EHR::SiteTime, :today, Date.new(2031, 1, 1)) do
      with_calendar(holidays: []) do
        get PATH

        assert_response :success
        assert_select "form[method='get'] [name='year'][value='2031']", count: 1
      end
    end
    assert_equal [ { start_date: Date.new(2031, 1, 1), end_date: Date.new(2031, 12, 31) } ], @holiday_reads
  end

  test "the documented year endpoints are accepted" do
    sign_in
    %w[1800 2699].each do |year|
      with_calendar(holidays: []) do
        get PATH, params: { year: year }

        assert_response :success
      end
      assert_equal [ { start_date: Date.new(year.to_i, 1, 1), end_date: Date.new(year.to_i, 12, 31) } ], @holiday_reads
    end
  end

  test "a malformed or out-of-range explicit year is refused before reading holidays" do
    sign_in
    [ "", "202", "02027", "1799", "2700", "2027x", "2027.0", " 2027", "2027\n", [ "2027" ], { value: "2027" } ].each do |year|
      with_calendar do
        get PATH, params: { year: year }

        assert_response :bad_request
      end
      assert_empty @holiday_reads
      assert_empty @writes
    end
  end

  test "an empty successful holiday read is not an unavailable result" do
    sign_in
    with_calendar(holidays: []) do
      get PATH, params: { year: "2027" }

      assert_response :success
      assert_select "#clinic-holidays-empty", count: 1
      assert_select "#clinic-holidays-unavailable", count: 0
    end
  end

  test "nil or malformed holiday replies never become an empty or partial calendar" do
    sign_in
    [ nil, {}, "bad", [ nil ], [ { date: "2027-01-01", name: "New year" } ],
      [ { date: Date.new(2027, 1, 1), name: nil } ],
      [ HOLIDAYS.first, { date: Date.new(2026, 12, 31), name: "Wrong year" } ],
      [ { date: Date.new(2028, 1, 1), name: "Wrong year" } ] ].each do |holidays|
      with_calendar(holidays: holidays) do
        get PATH, params: { year: "2027" }

        assert_response :service_unavailable
        assert_select "#clinic-holidays-unavailable", count: 1
        assert_select "#clinic-holidays-empty, #clinic-holidays tbody tr", count: 0
      end
    end
  end

  test "an unknown clinic holiday policy is unavailable rather than No" do
    sign_in
    [ nil, {}, [], { schedule_on_holidays: nil }, { schedule_on_holidays: "false" }, { schedule_on_holidays: 0 } ].each do |rules|
      with_calendar(rules: rules) do
        get PATH, params: { year: "2027" }

        assert_response :service_unavailable
        assert_select "#clinic-holidays-unavailable", count: 1
        assert_select "#clinic-holidays-empty, #clinic-holiday-policy", count: 0
      end
    end
  end

  test "a failed holiday or rules read is generic and never leaks broker details" do
    sign_in
    [ :holiday_error, :rules_error ].each do |source|
      with_calendar(**{ source => RpmsRpc::Client::RpcError.new("private broker detail") }) do
        get PATH, params: { year: "2027" }

        assert_response :service_unavailable
        assert_select "#clinic-holidays-unavailable", count: 1
        assert_no_match(/private broker detail/, response.body)
        assert_select "#clinic-holidays-empty", count: 0
      end
    end
  end

  test "an unsigned request is redirected without reading holiday data" do
    with_calendar do
      get PATH, params: { year: "2027" }

      assert_redirected_to "/lakeraven-ehr/login"
    end
    assert_empty @holiday_reads
    assert_empty @rule_reads
  end

  test "a user without scheduling capability cannot read holiday data" do
    sign_in("registration_menu")
    with_calendar do
      get PATH, params: { year: "2027" }

      assert_response :forbidden
    end
    assert_empty @holiday_reads
    assert_empty @rule_reads
  end

  test "unknown hidden and non-clinic resources cannot read holiday data" do
    sign_in
    [ [], [ RESOURCE.merge(view: false) ], [ RESOURCE.merge(hospital_location_id: nil) ] ].each do |resources|
      with_calendar(resources: resources) do
        get PATH, params: { year: "2027" }

        assert_response :not_found
      end
      assert_empty @holiday_reads
      assert_empty @rule_reads
    end
  end

  test "a backend without BPRM scheduling cannot read holiday data" do
    sign_in
    with_calendar do
      with_restricted_backend do
        get PATH, params: { year: "2027" }

        assert_response :not_found
      end
    end
    assert_empty @holiday_reads
    assert_empty @rule_reads
  end

  test "holiday names are escaped as text" do
    sign_in
    name = "<script>alert('holiday')</script>"
    with_calendar(holidays: [ { date: Date.new(2027, 1, 1), name: name } ]) do
      get PATH, params: { year: "2027" }

      assert_response :success
      assert_select "#clinic-holidays tbody td", text: name
      assert_select "#clinic-holidays script", count: 0
    end
  end

  test "each request reloads holidays and the clinic policy" do
    sign_in
    holidays = HOLIDAYS.dup
    rules = { schedule_on_holidays: false }
    with_calendar(holidays: holidays, rules: rules) do
      get PATH, params: { year: "2027" }
      assert_response :success
      assert_select "#clinic-holidays tbody tr", count: 2
      assert_select "#clinic-holiday-policy", text: /does not schedule|No/i

      holidays.replace([ { date: Date.new(2027, 6, 1), name: "New holiday" } ])
      rules[:schedule_on_holidays] = true
      get PATH, params: { year: "2027" }
      assert_response :success
      assert_select "#clinic-holidays tbody tr", count: 1
      assert_select "#clinic-holidays time[datetime='2027-06-01']", count: 1
      assert_select "#clinic-holiday-policy", text: /schedules on holidays|Yes/i
    end
    assert_equal 2, @holiday_reads.length
    assert_equal [ 23, 23 ], @rule_reads
    assert_empty @writes
  end
end
