# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-04: a scheduler searches a clinic for open times over a range
# of days. RPMS is stood in for at the gem boundary with the shapes a live
# rpms-ydb 7c3119b build answered: an 08:00-17:00 block of 4 slots each
# weekday, on a 15-minute grid. (BSDX SEARCH AVAILABILITY is not used: on the
# build it returns only a resource's first block, SEARCH^BSDX24.)
class SchedulingFindOpenTimeTest < ActionDispatch::IntegrationTest
  MONDAY = Date.new(2026, 11, 2)

  def at(day, hour, min = 0) = Time.new(day.year, day.month, day.day, hour, min)

  RESOURCES = [
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true }
  ].freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: keys }
  end

  GENERAL = SchedulingSetupStubs::GENERAL
  WALK_IN = { id: 4, name: "WALK IN", inactive: false, prevent_access: false }.freeze
  HELD = { id: 5, name: "HELD", inactive: false, prevent_access: true }.freeze

  # Monday to Friday blocks of DEMO GENERAL; Wednesday 10:00 holds four
  # appointments (full). extra adds blocks. setup: scheduling_setup_stubs's
  # rules:, holidays: and access_types:.
  def with_rpms(extra: [], **setup)
    days = (0..4).map { |i| MONDAY + i }
    blocks = days.flat_map do |d|
      [ { start_time: at(d, 0, 1), end_time: at(d, 8), slots: 0, access_type_id: 0 },
        { start_time: at(d, 8), end_time: at(d, 17), slots: 4, access_type_id: GENERAL[:id] } ]
    end + extra
    wednesday = MONDAY + 2
    full = Array.new(4) { |i| { id: 40 + i, start_time: at(wednesday, 10), end_time: at(wednesday, 10, 15), patient_dfn: 3, cancelled: false } }
    @reads = []
    reads = @reads
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { RESOURCES },
        slot_schedule: ->(**args) { reads << [ :slot_schedule, args ]; blocks.select { |b| (args[:start_date]..args[:end_date]).cover?(b[:start_time].to_date) } },
        appointments: ->(**args) { reads << [ :appointments, args ]; full.select { |a| (args[:start_date]..args[:end_date]).cover?(a[:start_time].to_date) } }
      }
    }.merge(scheduling_setup_stubs(**{ access_types: [ GENERAL, WALK_IN, HELD ] }.merge(setup)))
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def rules(**over)
    { id: 3, display_begins: nil, schedule_on_holidays: false, max_future_days: nil, prohibit_access: false,
      inactivate_date: nil, reactivate_date: nil }.merge(over)
  end

  def search(from, to, **params)
    get "/lakeraven-ehr/scheduling/clinics/2/open_times", params: { from: from.iso8601, to: to.iso8601, length: "15" }.merge(params)
    assert_response :ok
  end

  def closed(day) = css_select("#open-times [data-date='#{day.iso8601}']").first["data-closed"]

  def slots(day) = css_select("#open-times [data-date='#{day.iso8601}'] a[data-time]").map { |a| a["data-time"] }

  test "S-SCH-04.1 open times over a range lie in each day's blocks, with room, read once for the range" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2/open_times", params: { from: MONDAY.iso8601, to: (MONDAY + 4).iso8601, length: "15" }

      assert_response :ok
      assert_equal "08:00", slots(MONDAY).first
      assert_equal "16:45", slots(MONDAY).last
      refute_includes slots(MONDAY + 2), "10:00", "Wednesday 10:00 is full"
      assert_includes slots(MONDAY + 2), "10:15"
      assert_equal [ :slot_schedule, :appointments ], @reads.map(&:first), "one read of each for the whole range"
    end
  end

  test "S-SCH-04.5 the search can be kept to mornings or to afternoons" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2/open_times", params: { from: MONDAY.iso8601, to: MONDAY.iso8601, length: "15", part: "pm" }

      assert_equal "12:00", slots(MONDAY).first
      assert(slots(MONDAY).all? { |t| t >= "12:00" })
    end
  end

  test "S-SCH-04.1 no time is offered before the clinic's display start hour" do
    sign_in("scheduling_user")
    with_rpms(rules: rules(display_begins: 9)) do
      search(MONDAY, MONDAY)

      assert_equal "09:00", slots(MONDAY).first
    end
  end

  test "S-SCH-04.2 no time is offered in a block whose access type prevents access, and it cannot be booked" do
    tuesday = MONDAY + 1
    held = { start_time: at(tuesday, 17), end_time: at(tuesday, 18), slots: 2, access_type_id: HELD[:id] }
    sign_in("scheduling_user")
    with_rpms(extra: [ held ]) do
      search(tuesday, tuesday)

      assert_equal "16:45", slots(tuesday).last
      refute_includes css_select("#access_type option").map(&:text), "HELD", "a type that prevents access is not offered"

      post "/lakeraven-ehr/scheduling/clinics/2/appointments", params: { booking: { patient_dfn: "3", start: "#{tuesday.iso8601}T17:15", length: "15", note: "" } }
      assert_response :conflict
    end
  end

  test "S-SCH-04.3 a holiday has no time at a clinic that does not schedule on holidays, and its times at one that does" do
    holiday = MONDAY + 3
    sign_in("scheduling_user")
    with_rpms(rules: rules(schedule_on_holidays: false), holidays: [ { date: holiday, name: "HOLIDAY" } ]) do
      search(MONDAY, MONDAY + 4)

      assert_empty slots(holiday)
      assert_equal "holiday", closed(holiday)
      refute_empty slots(holiday - 1)
    end
    with_rpms(rules: rules(schedule_on_holidays: true), holidays: [ { date: holiday, name: "HOLIDAY" } ]) do
      search(holiday, holiday)

      assert_equal "08:00", slots(holiday).first
      assert_equal "", closed(holiday)
    end
  end

  test "S-SCH-04.4 no time is offered past the clinic's limit for booking ahead, or while it is inactive" do
    sign_in("scheduling_user")
    travel_to Time.new(2026, 10, 30, 9) do
      with_rpms(rules: rules(max_future_days: 4)) do
        search(MONDAY, MONDAY + 4)

        refute_empty slots(MONDAY), "Monday is 3 days ahead"
        refute_empty slots(MONDAY + 1), "Tuesday is the 4th day ahead"
        assert_empty slots(MONDAY + 2)
        assert_equal "beyond_booking", closed(MONDAY + 2)
      end
      with_rpms(rules: rules(inactivate_date: MONDAY + 1, reactivate_date: MONDAY + 3)) do
        search(MONDAY, MONDAY + 4)

        assert_equal [ false, true, true, false, false ], (0..4).map { |i| slots(MONDAY + i).empty? }
        assert_equal "inactive", closed(MONDAY + 2)
      end
    end
  end

  test "S-SCH-04.6 the search can be kept to one access type" do
    thursday = MONDAY + 3
    walk_in = { start_time: at(thursday, 17), end_time: at(thursday, 18), slots: 2, access_type_id: WALK_IN[:id] }
    sign_in("scheduling_user")
    with_rpms(extra: [ walk_in ]) do
      search(MONDAY, thursday, access_type: WALK_IN[:id])

      assert_equal %w[17:00 17:15 17:30 17:45], slots(thursday)
      assert_empty slots(MONDAY + 2), "Wednesday has no WALK IN block"
      assert_equal WALK_IN[:id].to_s, css_select("#access_type option[selected]").first["value"]
    end
  end

  test "S-SCH-04.7 an open time opens the booking form at that time, with the length searched for" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/clinics/2/open_times", params: { from: MONDAY.iso8601, to: MONDAY.iso8601, length: "30" }
      link = css_select("#open-times [data-date='#{MONDAY.iso8601}'] a[data-time='09:00']").first

      assert_equal "/lakeraven-ehr/scheduling/clinics/2/appointments/new?length=30&start=2026-11-02T09%3A00", link["href"]
    end
  end

  test "without a scheduling key the search is closed" do
    sign_in("registration_menu")
    get "/lakeraven-ehr/scheduling/clinics/2/open_times"

    assert_response :forbidden
  end
end
