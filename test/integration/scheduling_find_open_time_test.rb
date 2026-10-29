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

  # Monday to Friday blocks; Wednesday 10:00 holds four appointments (full).
  def with_rpms
    days = (0..4).map { |i| MONDAY + i }
    blocks = days.flat_map { |d| [ { start_time: at(d, 0, 1), end_time: at(d, 8), slots: 0 }, { start_time: at(d, 8), end_time: at(d, 17), slots: 4 } ] }
    wednesday = MONDAY + 2
    full = Array.new(4) { |i| { id: 40 + i, start_time: at(wednesday, 10), end_time: at(wednesday, 10, 15), patient_dfn: 3, cancelled: false } }
    @reads = []
    sched = RpmsRpc::Scheduling.singleton_class
    reads = @reads
    stubs = {
      resources: ->(*) { RESOURCES },
      slot_schedule: ->(**args) { reads << [ :slot_schedule, args ]; blocks.select { |b| (args[:start_date]..args[:end_date]).cover?(b[:start_time].to_date) } },
      appointments: ->(**args) { reads << [ :appointments, args ]; full.select { |a| (args[:start_date]..args[:end_date]).cover?(a[:start_time].to_date) } }
    }
    stubs.each_key { |m| sched.alias_method(:"__#{m}", m) }
    stubs.each { |m, body| sched.define_method(m, &body) }
    yield
  ensure
    stubs.each_key { |m| sched.alias_method(m, :"__#{m}"); sched.remove_method(:"__#{m}") }
  end

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
