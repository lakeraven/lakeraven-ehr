# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-19 (#616): a scheduling supervisor adds and removes a holiday.
# HOLIDAY (#40.5) is one site-wide file, a row per date, so a holiday applies to
# every clinic; a clinic set to schedule on holidays still takes bookings. RPMS
# is stood in for at the gem boundary (RpmsRpc::SchedulingSetup, rpms-rpc
# 5c291bc) with the shapes its add_holiday, remove_holiday and holidays answer.
# All data is synthetic.
class SchedulingHolidaysTest < ActionDispatch::IntegrationTest
  TODAY = Date.new(2031, 6, 2)
  FOURTH = Date.new(2031, 7, 4) # a Friday
  FOUNDERS = { date: FOURTH, name: "DEMO FOUNDERS DAY" }.freeze
  INDEX = "/lakeraven-ehr/scheduling/holidays"
  REMOVE_FOURTH = "/lakeraven-ehr/scheduling/holidays/2031-07-04/remove"

  RESOURCES = [
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true }
  ].freeze

  RULES = { id: 3, display_begins: nil, schedule_on_holidays: false, max_future_days: nil, prohibit_access: false,
            inactivate_date: nil, reactivate_date: nil }.freeze

  ADDED = ->(_args) { { success: true } }
  REMOVED = ->(_date) { { success: true } }

  setup { travel_to Time.new(2031, 6, 2, 9) }

  def at(day, hour, min = 0) = Time.new(day.year, day.month, day.day, hour, min)

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_type: "user", user_name: "MANAGER,SYSTEM", security_keys: keys }
  end

  # Stands in for the gem. The holiday list is stateful: a successful add
  # appends to what holidays returns, a successful remove deletes from it.
  # Every write and every holidays read is recorded.
  def with_rpms(holidays: [], add: ADDED, remove: REMOVED, read: nil, rules: RULES)
    @writes = []
    @reads = []
    list = holidays.dup
    writes = @writes
    reads = @reads
    blocks = [ { start_time: at(FOURTH, 0, 1), end_time: at(FOURTH, 8), slots: 0, access_type_id: 0 },
               { start_time: at(FOURTH, 8), end_time: at(FOURTH, 17), slots: 4, access_type_id: SchedulingSetupStubs::GENERAL[:id] } ]
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { RESOURCES },
        slot_schedule: ->(**args) { blocks.select { |b| (args[:start_date]..args[:end_date]).cover?(b[:start_time].to_date) } },
        appointments: ->(**) { [] }
      }
    }.merge(scheduling_setup_stubs(rules: rules))
    stubs[RpmsRpc::SchedulingSetup.singleton_class].merge!(
      holidays: lambda { |start_date:, end_date:|
        reads << { start_date: start_date, end_date: end_date }
        read&.call
        list.select { |h| (start_date..end_date).cover?(h[:date]) }.sort_by { |h| h[:date] }
      },
      add_holiday: lambda { |**args|
        writes << [ :add_holiday, args ]
        result = add.call(args)
        list << { date: args[:date], name: args[:name] } if result.is_a?(Hash) && result[:success]
        result
      },
      remove_holiday: lambda { |date|
        writes << [ :remove_holiday, date ]
        result = remove.call(date)
        list.reject! { |h| h[:date] == date } if result.is_a?(Hash) && result[:success]
        result
      }
    )
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def writes = @writes || []

  def add(date:, name:)
    post INDEX, params: { holiday: { date: date, name: name }.compact }
  end

  def open_slots(day)
    get "/lakeraven-ehr/scheduling/clinics/2/open_times", params: { from: day.iso8601, to: day.iso8601, length: "15" }
    assert_response :ok
    css_select("#open-times [data-date='#{day.iso8601}'] a[data-time]").map { |a| a["data-time"] }
  end

  def closed(day) = css_select("#open-times [data-date='#{day.iso8601}']").first["data-closed"]

  def assert_no_success
    assert_select "#holiday-notice", count: 0
    assert_nil flash[:notice]
  end

  test "S-SCH-19.1 the supervisor adds a holiday, sent once with its date and its name in capitals" do
    sign_in("scheduling_supervisor")
    with_rpms(holidays: [ { date: Date.new(2031, 11, 27), name: "DEMO HARVEST DAY" }, { date: Date.new(2033, 1, 3), name: "DEMO FAR DAY" } ]) do
      get INDEX
      assert_response :ok
      assert_equal [ { start_date: TODAY, end_date: Date.new(2032, 6, 2) } ], @reads, "today through one year ahead"
      assert_select "#holidays tr[data-holiday]", count: 1
      assert_select "#holidays tr[data-holiday='2031-11-27']", text: /2031-11-27/
      assert_select "#holidays tr[data-holiday='2031-11-27']", text: /DEMO HARVEST DAY/
      assert_select "body", text: /every clinic/
      assert_select "body", text: /schedule on holidays/i

      add(date: "2031-07-04", name: "  Demo Founders Day ")
      assert_redirected_to INDEX
      follow_redirect!
      assert_select "#holiday-notice", text: /DEMO FOUNDERS DAY/
      assert_select "#holidays tr[data-holiday='2031-07-04']", text: /DEMO FOUNDERS DAY/
    end

    assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes
    assert_instance_of Date, writes.first.last[:date]
  end

  test "S-SCH-19.2 the supervisor removes a listed holiday, sent once by its date" do
    sign_in("scheduling_supervisor")
    with_rpms(holidays: [ FOUNDERS ]) do
      get INDEX
      assert_select "#holidays tr[data-holiday='2031-07-04'] form[action='#{REMOVE_FOURTH}']"

      post REMOVE_FOURTH
      assert_redirected_to INDEX
      follow_redirect!
      assert_select "#holidays tr[data-holiday='2031-07-04']", count: 0
    end

    assert_equal [ [ :remove_holiday, FOURTH ] ], writes
    assert_instance_of Date, writes.first.last
  end

  test "S-SCH-19.3 a holiday without a usable name or date is refused here, with no RPC" do
    sign_in("scheduling_supervisor")
    refused = {
      "a blank name" => { date: "2031-07-04", name: "   ", error: /Name/i },
      "no date" => { date: nil, name: "DEMO FOUNDERS DAY", error: /Date/i },
      "an empty date" => { date: "", name: "DEMO FOUNDERS DAY", error: /Date/i },
      "a date not in the calendar" => { date: "2031-02-30", name: "DEMO FOUNDERS DAY", error: /Date/i },
      "a date in words" => { date: "tomorrow", name: "DEMO FOUNDERS DAY", error: /Date/i },
      "a date in the past" => { date: "2031-06-01", name: "DEMO FOUNDERS DAY", error: /Date/i },
      "a name over 30 characters" => { date: "2031-07-04", name: "DEMO FOUNDERS DAY OBSERVED LONG", error: /Name/i },
      "a name with a caret" => { date: "2031-07-04", name: "DEMO^FOUNDERS", error: /Name/i }
    }
    with_rpms do
      refused.each do |what, holiday|
        add(**holiday.slice(:date, :name))

        assert_response :unprocessable_content, what
        assert_select "#holiday-errors", { text: holiday[:error] }, what
        assert_no_success
        assert_empty writes, what
      end
    end
  end

  test "S-SCH-19.4 RPMS's refusal of a holiday already on file is shown" do
    sign_in("scheduling_supervisor")
    exists = ->(_args) { { success: false, error: :filer_failed, message: "Entry '3310704,' already exists." } }
    with_rpms(holidays: [ FOUNDERS ], add: exists) do
      add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

      assert_response :unprocessable_content
      assert_select "#holiday-alert", text: /Entry '3310704,' already exists\./
      assert_no_success
    end

    assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes
  end

  test "S-SCH-19.5 removing a date with no holiday says so and claims no success" do
    sign_in("scheduling_supervisor")
    none = ->(_date) { { success: false, error: :not_found, message: "no holiday on that date" } }
    with_rpms(remove: none) do
      post REMOVE_FOURTH
      assert_redirected_to INDEX
      assert_nil flash[:notice]
      follow_redirect!

      assert_response :ok
      assert_select "#holiday-alert", text: /no holiday on that date/i
      assert_select "#holiday-notice", count: 0
    end

    assert_equal [ [ :remove_holiday, FOURTH ] ], writes
  end

  test "S-SCH-19.6 an add or remove RPMS did not confirm fails closed" do
    sign_in("scheduling_supervisor")
    unknown = { "no reply" => ->(_) { nil }, "an error" => ->(_) { raise RpmsRpc::Error, "connection lost" } }
    unknown.each do |what, outcome|
      with_rpms(add: outcome) do
        add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

        assert_response :service_unavailable, "add: #{what}"
        assert_select "#holiday-alert", { text: /check the holidays before/i }, "add: #{what}"
        assert_no_success
        assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes, "add: #{what}, sent once and not retried"
      end
      with_rpms(holidays: [ FOUNDERS ], remove: outcome) do
        post REMOVE_FOURTH

        assert_response :service_unavailable, "remove: #{what}"
        assert_select "#holiday-alert", { text: /check the holidays before/i }, "remove: #{what}"
        assert_no_success
        assert_equal [ [ :remove_holiday, FOURTH ] ], writes, "remove: #{what}, sent once and not retried"
      end
    end
  end

  test "S-SCH-19.7 a failed read of the holidays is not shown as a list with none" do
    sign_in("scheduling_supervisor")
    with_rpms(holidays: [ FOUNDERS ], read: -> { raise RpmsRpc::Error, "read failed" }) do
      get INDEX

      assert_response :service_unavailable
      assert_select "#holiday-alert"
      assert_select "#holidays tr[data-holiday]", count: 0
      assert_no_match(/no holidays/i, response.body)
      assert_equal 1, @reads.size
    end
  end

  test "S-SCH-19.8 a scheduler without SDZSUP cannot list, add or remove holidays; the supervisor has the link" do
    sign_in("scheduling_user")
    with_rpms(holidays: [ FOUNDERS ]) do
      get "/lakeraven-ehr/scheduling"
      assert_response :ok
      assert_select "#holidays-link", count: 0
      get INDEX
      assert_response :forbidden
      add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")
      assert_response :forbidden
      post REMOVE_FOURTH
      assert_response :forbidden

      assert_empty writes
      assert_empty @reads, "the holidays are not read for someone who may not see them"
    end

    sign_in("scheduling_supervisor")
    with_rpms do
      get "/lakeraven-ehr/scheduling"
      assert_select "#holidays-link[href='#{INDEX}']"
    end
  end

  test "S-SCH-19.9 a holiday added for a clinic date removes its open slots, and removing it restores them" do
    sign_in("scheduling_supervisor")
    with_rpms do
      before = open_slots(FOURTH)
      assert_equal "08:00", before.first
      assert_equal "16:45", before.last
      assert_equal "", closed(FOURTH)

      add(date: "2031-07-04", name: "Demo Founders Day")
      assert_redirected_to INDEX

      assert_empty open_slots(FOURTH)
      assert_equal "holiday", closed(FOURTH)

      post REMOVE_FOURTH
      assert_redirected_to INDEX

      assert_equal before, open_slots(FOURTH)
      assert_equal "", closed(FOURTH)
    end

    assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ], [ :remove_holiday, FOURTH ] ], writes
  end

  test "S-SCH-19.10 a remove whose date is not a date is refused with no RPC" do
    sign_in("scheduling_supervisor")
    with_rpms(holidays: [ FOUNDERS ]) do
      %w[2031-13-01 2031-02-30 tomorrow 20310704].each do |bad|
        post "/lakeraven-ehr/scheduling/holidays/#{bad}/remove"

        assert_response :not_found, bad
        assert_empty writes, bad
      end

      # The same route with a real date does remove.
      post REMOVE_FOURTH
      assert_redirected_to INDEX
    end

    assert_equal [ [ :remove_holiday, FOURTH ] ], writes
  end
end
