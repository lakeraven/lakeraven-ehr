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
  def with_rpms(holidays: [], add: ADDED, remove: REMOVED, read: nil, listing: nil, rules: RULES)
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
        next listing.call if listing # a reply of some other shape, returned as it is
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
      assert_select "#holiday-alert", text: /no holiday on 2031-07-04/i
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

  # --- amendment round 1 -------------------------------------------------

  def with_site_clock(time)
    Lakeraven::EHR::SiteTime.reader = -> { time }
    yield
  ensure
    Lakeraven::EHR::SiteTime.reader = -> { Time.now }
  end

  def alert_text = css_select("#holiday-alert").map { |node| node.text.strip }.join(" ")

  test "S-SCH-19.11 today is the site's clock, not the app server's" do
    travel_back
    travel_to Time.new(2031, 6, 3, 2) # the app server is already on the 3rd
    sign_in("scheduling_supervisor")
    with_site_clock(Time.new(2031, 6, 2, 19)) do
      with_rpms(holidays: [ { date: TODAY, name: "DEMO SITE DAY" } ]) do
        get INDEX
        assert_response :ok
        assert_equal [ { start_date: TODAY, end_date: Date.new(2032, 6, 2) } ], @reads, "the site's today through one year ahead"
        assert_select "#holidays tr[data-holiday='2031-06-02'] form[action='/lakeraven-ehr/scheduling/holidays/2031-06-02/remove']"
      end

      with_rpms do
        add(date: "2031-06-02", name: "DEMO SITE DAY")
        assert_redirected_to INDEX
        follow_redirect!
        assert_select "#holiday-notice", text: /DEMO SITE DAY/
        assert_equal [ [ :add_holiday, { date: TODAY, name: "DEMO SITE DAY" } ] ], writes
      end

      with_rpms do
        add(date: "2031-06-01", name: "DEMO SITE DAY")
        assert_response :unprocessable_content
        assert_select "#holiday-errors", text: /Date/i
        assert_no_success
        assert_empty writes
      end
    end
  end

  test "S-SCH-19.12 a holidays read that is not a list of dated rows is a failed read" do
    sign_in("scheduling_supervisor")
    odd = {
      "nil" => nil,
      "a Hash" => { date: FOURTH, name: "X" },
      "a row with no date" => [ FOUNDERS, { date: nil, name: "DEMO NO DATE" } ]
    }
    odd.each do |what, value|
      with_rpms(holidays: [ FOUNDERS ], listing: -> { value }) do
        get INDEX

        assert_response :service_unavailable, what
        assert_select "#holiday-alert", {}, what
        assert_select "#holidays tr[data-holiday]", { count: 0 }, what
        assert_no_match(/no holidays/i, response.body, what)
      end
    end
  end

  test "S-SCH-19.13 a write reply that does not plainly say success is an unknown outcome" do
    sign_in("scheduling_supervisor")
    replies = { "true" => true, "a string" => "ok", "an empty list" => [], "an empty hash" => {},
                "success in words" => { success: "no" }, "a failure with no error" => { success: false } }
    replies.each do |what, reply|
      with_rpms(add: ->(_) { reply }) do
        add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

        assert_response :service_unavailable, "add: #{what}"
        assert_select "#holiday-alert", { text: /check the holidays before/i }, "add: #{what}"
        assert_no_success
        assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes, "add: #{what}, sent once"
      end
      with_rpms(holidays: [ FOUNDERS ], remove: ->(_) { reply }) do
        post REMOVE_FOURTH

        assert_response :service_unavailable, "remove: #{what}"
        assert_select "#holiday-alert", { text: /check the holidays before/i }, "remove: #{what}"
        assert_no_success
        assert_equal [ [ :remove_holiday, FOURTH ] ], writes, "remove: #{what}, sent once"
      end
    end
  end

  test "S-SCH-19.14 a refusal with an empty message still says RPMS refused" do
    sign_in("scheduling_supervisor")
    with_rpms(add: ->(_) { { success: false, error: :filer_failed, message: "" } }) do
      add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

      assert_response :unprocessable_content
      assert_select "#holiday-alert"
      assert_match(/RPMS did not add the holiday/, alert_text)
      assert_no_match(/:\s*\z/, alert_text)
      assert_no_success
    end

    assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes
  end

  test "S-SCH-19.15 a date past the list's year ahead is refused here, with no RPC" do
    sign_in("scheduling_supervisor")
    with_site_clock(Time.new(2031, 6, 2, 9)) do
      with_rpms do
        %w[2032-06-03 9999-12-31].each do |late|
          add(date: late, name: "DEMO FAR DAY")

          assert_response :unprocessable_content, late
          assert_select "#holiday-errors", { text: /Date/i }, late
          assert_no_success
          assert_empty writes, late
        end

        add(date: "2032-06-02", name: "DEMO FAR DAY")
        assert_redirected_to INDEX
      end
    end

    assert_equal [ [ :add_holiday, { date: Date.new(2032, 6, 2), name: "DEMO FAR DAY" } ] ], writes
  end

  test "S-SCH-19.16 a refused add whose list read also fails says both" do
    sign_in("scheduling_supervisor")
    exists = ->(_args) { { success: false, error: :filer_failed, message: "Entry '3310704,' already exists." } }
    with_rpms(holidays: [ FOUNDERS ], add: exists, read: -> { raise RpmsRpc::Error, "read failed" }) do
      add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

      assert_response :service_unavailable
      alerts = css_select("[id^='holiday-alert']").map(&:text).join(" ")
      assert_match(/Entry '3310704,' already exists\./, alerts)
      assert_match(/did not return the holidays/i, alerts)
      assert_select "#holidays tr[data-holiday]", count: 0
      assert_no_success
    end

    assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes
  end

  test "S-SCH-19.17 the not-found remove alert names the date and does not repeat itself" do
    sign_in("scheduling_supervisor")
    none = ->(_date) { { success: false, error: :not_found, message: "no holiday on that date" } }
    with_rpms(remove: none) do
      post REMOVE_FOURTH
      assert_redirected_to INDEX
      follow_redirect!

      assert_response :ok
      assert_match(/no holiday on 2031-07-04/i, alert_text)
      assert_equal 1, alert_text.scan(/no holiday/i).size, alert_text
    end

    assert_equal [ [ :remove_holiday, FOURTH ] ], writes
  end

  # --- amendment round 2 -------------------------------------------------

  # The gem's own words when DDR FILER answers without a [Data] line (rpms-rpc
  # ddr_fileman.rb, filer): the reply could not be read, so whether RPMS filed
  # is not known. It shares error: :filer_failed with a true FileMan refusal.
  NO_DATA_MARKER = { success: false, error: :filer_failed,
                     message: "no [Data] marker in DDR FILER reply: [Misc]" }.freeze

  test "S-SCH-19.18 a DDR FILER reply with no [Data] line is an unknown outcome, not a refusal" do
    sign_in("scheduling_supervisor")
    with_rpms(add: ->(_) { NO_DATA_MARKER }) do
      add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

      assert_response :service_unavailable
      assert_select "#holiday-alert", text: /check the holidays before/i
      assert_no_success
      assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes, "sent once and not retried"
    end
    with_rpms(holidays: [ FOUNDERS ], remove: ->(_) { NO_DATA_MARKER }) do
      post REMOVE_FOURTH

      assert_response :service_unavailable
      assert_select "#holiday-alert", text: /check the holidays before/i
      assert_no_success
      assert_equal [ [ :remove_holiday, FOURTH ] ], writes, "sent once and not retried"
    end
  end

  test "S-SCH-19.19 a refusal with no readable reason never shows an internal code" do
    sign_in("scheduling_supervisor")
    with_rpms(add: ->(_) { { success: false, error: :filer_failed, message: "" } }) do
      add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

      assert_response :unprocessable_content
      assert_select "#holiday-alert"
      assert_match(/RPMS did not add the holiday/, alert_text)
      assert_no_match(/filer_failed/i, alert_text)
      assert_no_match(/filer_failed/i, response.body)
      assert_no_success
    end

    assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes
  end

  test "S-SCH-19.20 a holidays read RPMS refuses to this user is a refusal, with RPMS's reason" do
    sign_in("scheduling_supervisor")
    refusal = "DDR LISTER is not in this user's context"
    with_rpms(holidays: [ FOUNDERS ], read: -> { raise RpmsRpc::Client::RpcRefusedError, refusal }) do
      get INDEX

      assert_response :forbidden
      assert_select "[role=alert]", text: /RPMS refused.*DDR LISTER is not in this user's context/m
      assert_select "#holidays tr[data-holiday]", count: 0
      assert_no_match(/no holidays/i, response.body)
      assert_equal 1, @reads.size
    end
  end

  test "S-SCH-19.21 a remove for a date before the site's today is refused here, with no RPC" do
    sign_in("scheduling_supervisor")
    with_site_clock(Time.new(2031, 6, 2, 9)) do
      with_rpms(holidays: [ { date: Date.new(2031, 6, 1), name: "DEMO PAST DAY" }, { date: TODAY, name: "DEMO SITE DAY" } ]) do
        %w[2031-06-01 2030-12-25].each do |past|
          post "/lakeraven-ehr/scheduling/holidays/#{past}/remove"

          assert_response :not_found, past
          assert_nil flash[:notice], past
          assert_empty writes, past
        end

        # The site's today is still removable.
        post "/lakeraven-ehr/scheduling/holidays/2031-06-02/remove"
        assert_redirected_to INDEX
      end
    end

    assert_equal [ [ :remove_holiday, TODAY ] ], writes
  end

  # --- amendment round 3 -------------------------------------------------

  REFUSED_READ = -> { raise RpmsRpc::Client::RpcRefusedError, "DDR LISTER is not in this user's context" }

  def holiday_alerts = css_select("[id^='holiday-alert']").map { |node| node.text.strip }.join(" ")

  def assert_no_list
    assert_select "#holidays tr[data-holiday]", count: 0
    assert_no_match(/no holidays/i, response.body)
  end

  # Reports the RPMS connection closed once the block given to it has set the
  # flag, the way a broker that dropped mid-write does: open when the request
  # is authenticated, closed by the time the page is rendered.
  def with_rpms_connection(closed)
    web = Lakeraven::EHR::WebController
    web.alias_method(:__rpms_connection_closed?, :rpms_connection_closed?)
    web.define_method(:rpms_connection_closed?) { closed.call }
    web.send(:private, :rpms_connection_closed?)
    yield
  ensure
    web.alias_method(:rpms_connection_closed?, :__rpms_connection_closed?)
    web.remove_method(:__rpms_connection_closed?)
    web.send(:private, :rpms_connection_closed?)
  end

  test "S-SCH-19.22 an unconfirmed add keeps its warning when RPMS then refuses the holidays read" do
    sign_in("scheduling_supervisor")
    with_rpms(add: ->(_) { nil }, read: REFUSED_READ) do
      add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

      assert_response :service_unavailable
      assert_select "#holiday-alert", text: /check the holidays before/i
      assert_no_list
      assert_no_success
      assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes, "sent once and not retried"
    end
  end

  test "S-SCH-19.23 an unconfirmed remove keeps its warning when RPMS then refuses the holidays read" do
    sign_in("scheduling_supervisor")
    with_rpms(holidays: [ FOUNDERS ], remove: ->(_) { nil }, read: REFUSED_READ) do
      post REMOVE_FOURTH

      assert_response :service_unavailable
      assert_select "#holiday-alert", text: /check the holidays before/i
      assert_no_list
      assert_no_success
      assert_equal [ [ :remove_holiday, FOURTH ] ], writes, "sent once and not retried"
    end
  end

  test "S-SCH-19.24 a refused add still names its refusal when RPMS then refuses the holidays read" do
    sign_in("scheduling_supervisor")
    exists = ->(_args) { { success: false, error: :filer_failed, message: "Entry '3310704,' already exists." } }
    with_rpms(holidays: [ FOUNDERS ], add: exists, read: REFUSED_READ) do
      add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

      assert_operator response.status, :>=, 400, "not a success"
      assert_match(/RPMS did not add the holiday/, holiday_alerts)
      assert_no_list
      assert_no_success
    end

    assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes
  end

  # The 503 page is kept rather than the login redirect: the add may have
  # filed, and the redirect's one-shot flash on the sign-in page is the easier
  # of the two to miss. The session still ends on the supervisor's next request
  # (WebController#require_authentication), so nothing stays signed in.
  test "S-SCH-19.25 an add cut off by a closed RPMS connection still says the change was not confirmed" do
    sign_in("scheduling_supervisor")
    closed = false
    dropped = ->(_) { closed = true; raise IOError, "closed stream" }
    with_rpms_connection(-> { closed }) do
      with_rpms(add: dropped, read: -> { raise IOError, "closed stream" if closed }) do
        add(date: "2031-07-04", name: "DEMO FOUNDERS DAY")

        assert_response :service_unavailable
        assert_select "#holiday-alert", text: /check the holidays before/i
        assert_no_list
        assert_no_success
        assert_equal [ [ :add_holiday, { date: FOURTH, name: "DEMO FOUNDERS DAY" } ] ], writes, "sent once and not retried"
      end
    end
  end

  # A broker stand-in below the gem: the real RpmsRpc::SchedulingSetup and
  # RpmsRpc::DdrFileman run, and only the wire reply is made up. It cannot bind
  # a context, so ContextScope runs the call as it is.
  class ReplyingClient
    attr_reader :calls

    def initialize(reply)
      @reply = reply
      @calls = []
    end

    def call_rpc(name, *params)
      @calls << [ name, params ]
      @reply
    end
  end

  test "S-SCH-19.26 the pinned gem's words for a DDR FILER reply with no [Data] line are an unknown outcome" do
    broker = ReplyingClient.new("[Misc]")
    result = RpmsRpc.with_client(broker) do
      Lakeraven::EHR::SchedulingTablesGateway.add_holiday(FOURTH, "DEMO FOUNDERS DAY")
    end

    assert_equal :unknown, result.status
    assert_not result.saved?
    assert_equal [ "DDR FILER" ], broker.calls.map(&:first), "one FILER call, through the real gem"

    filed = RpmsRpc.with_client(ReplyingClient.new("[Misc]")) do
      RpmsRpc::DdrFileman.filer(mode: "ADD", rows: [ { file: "40.5", field: ".01", iens: "+1,", value: "3310704" } ])
    end
    assert_equal false, filed[:success]
    assert filed[:errors].first.start_with?(Lakeraven::EHR::SchedulingTablesGateway::NO_DATA_MARKER), filed[:errors].first
  end

  test "S-SCH-19.27 a holiday parameter that is not a form is refused, with no RPC" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post INDEX, params: { holiday: "x" }

      assert_includes [ 400, 422 ], response.status
      assert_no_success
      assert_empty writes
    end
  end
end
