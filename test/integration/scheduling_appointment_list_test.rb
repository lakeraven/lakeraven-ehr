# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-05.5: the appointments across a scheduler's clinics, filtered
# and sorted. RPMS is stood in for at the gem boundary.
class SchedulingAppointmentListTest < ActionDispatch::IntegrationTest
  TODAY = Date.new(2027, 1, 6)
  RESOURCES = [
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3, view: true },
    { id: 5, name: "SECOND CLINIC", inactive: false, time_scale: 15, hospital_location_id: 8, view: true },
    { id: 7, name: "NOT MINE", inactive: false, time_scale: 15, hospital_location_id: 9, view: false }
  ].freeze

  def at(hour, min = 0, on: TODAY) = Time.new(on.year, on.month, on.day, hour, min)

  def row(id, time, name = "MOUSE,MICKEY M", **state)
    { id: id, start_time: time, end_time: time + 900, patient_dfn: id, patient_name: name, cancelled: false, no_show: false,
      checkin_time: nil, checkout_time: nil }.merge(state)
  end

  ROWS = {
    "DEMO IHS CLINIC" => ->(t) {
      [ t.row(1, t.at(11), "ZULU,ROBIN"),
        t.row(2, t.at(9), "ALPHA,CASEY", checkin_time: t.at(9, 5)),
        t.row(3, t.at(8), "BRAVO,KIT", checkin_time: t.at(8, 5), checkout_time: t.at(8, 30)),
        t.row(9, t.at(9, on: TODAY + 7), "FUTURE,SAM"),
        t.row(10, t.at(9, on: TODAY - 7), "PAST,JO") ]
    },
    "SECOND CLINIC" => ->(t) {
      [ t.row(4, t.at(10), "CHARLIE,LEE", checkin_time: t.at(7, 55)),
        t.row(5, t.at(10, 30), "DELTA,RAE", checkin_time: t.at(10, 25), cancelled: true),
        t.row(6, t.at(12), "ECHO,PAT", no_show: true) ]
    }
  }.freeze

  def sign_in
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" }
  end

  def with_rpms(failing: false)
    test_case = self
    @asked = []
    asked = @asked
    restores = [ StubHelpers.send(:singleton_method_restore, RpmsRpc::Scheduling, :resources),
                 StubHelpers.send(:singleton_method_restore, RpmsRpc::Scheduling, :appointments) ]
    RpmsRpc::Scheduling.define_singleton_method(:resources) { |*| RESOURCES }
    RpmsRpc::Scheduling.define_singleton_method(:appointments) do |resource:, start_date:, end_date:|
      raise RpmsRpc::Client::RpcError, "no reply" if failing

      asked << resource
      ROWS.fetch(resource).call(test_case).select { |a| (start_date..end_date).cover?(a[:start_time].to_date) }
    end
    travel_to(TODAY.to_time.change(hour: 13)) do
      sign_in
      yield
    end
  ensure
    restores&.each(&:call)
  end

  def listed = css_select("#appointment-list tbody tr").map { |tr| tr["data-appointment"].to_i }

  def list(**filters) = get("/lakeraven-ehr/scheduling/appointments", params: filters)

  test "S-SCH-05.5 today's appointments across my clinics, by appointment time, and only my clinics" do
    with_rpms { list }

    assert_response :ok
    assert_equal [ 3, 2, 4, 5, 1, 6 ], listed
    assert_equal [ "DEMO IHS CLINIC", "SECOND CLINIC" ], @asked
  end

  test "S-SCH-05.5 filtered to checked in, those checked out or cancelled are not listed" do
    with_rpms { list(status: "checked") }

    assert_equal [ 2, 4 ], listed
  end

  test "S-SCH-05.5 future, past and all, and each status" do
    with_rpms do
      list(when: "future")
      assert_equal [ 9 ], listed
      list(when: "past")
      assert_equal [ 10 ], listed
      list(when: "all")
      assert_equal [ 10, 3, 2, 4, 5, 1, 6, 9 ], listed
      list(status: "no-show")
      assert_equal [ 6 ], listed
      list(status: "cancelled")
      assert_equal [ 5 ], listed
      list(status: "checked-out")
      assert_equal [ 3 ], listed
    end
  end

  test "S-SCH-05.5 sorted by patient, by check-in and by check-out, with no such time last" do
    with_rpms do
      list(sort: "patient")
      assert_equal [ 2, 3, 4, 5, 6, 1 ], listed
      list(sort: "checkin")
      assert_equal [ 4, 3, 2, 5, 1, 6 ], listed
      list(sort: "checkout")
      assert_equal [ 3, 2, 4, 5, 1, 6 ], listed
    end
  end

  test "an unknown choice falls back, and a list with none says so" do
    with_rpms do
      list(when: "soon", status: "lost", sort: "shoe")
      assert_equal [ 3, 2, 4, 5, 1, 6 ], listed
      list(when: "future", status: "no-show")
      assert_select "#no-appointments", text: /No appointments match/
    end
  end

  test "a failed read says so, not an empty list" do
    with_rpms(failing: true) { list }

    assert_select "#appointment-list-unread"
    assert_select "#no-appointments", 0
  end

  test "without scheduling, the list is closed" do
    post "/lakeraven-ehr/test_session", params: { duz: "207", user_type: "user", user_name: "PROFILE,REG", security_keys: "registration_menu" }
    list

    assert_response :forbidden
  end
end
