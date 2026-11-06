# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-10: a clinic's wait list. RpmsRpc::WaitList and the booking are
# stood in for at the gem boundary. The live test proves the filing.
class SchedulingWaitListTest < ActionDispatch::IntegrationTest
  BASE = "/lakeraven-ehr/scheduling/clinics/2/wait_list"
  DAY = Date.new(2027, 1, 6)
  RESOURCE = { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
               view: true, overbook: false, modify_schedule: false, modify_appointments: true }.freeze
  LOOK_ONLY = RESOURCE.merge(modify_appointments: false).freeze
  LIST = { ien: 9, clinic_ien: 3, clinic: "DEMO", inactive: false }.freeze

  def entry(ien, recall, priority: "2", open: true, **rest)
    { ien: ien, patient_dfn: 3, patient: "MOUSE,MICKEY M", priority: priority, added_on: DAY, recall_on: recall, provider_ien: nil,
      provider: "", removed_on: (DAY unless open), resolution_ien: nil, resolution: (open ? "" : "PATIENT NO LONGER NEEDS APPT"),
      reason_ien: 3, reason: "F/U PATIENT; NO SCHEDULE YET", open: open }.merge(rest)
  end

  def sign_in
    post "/lakeraven-ehr/test_session", params: { duz: "208", user_type: "user", user_name: "PROFILE,SCHED", security_keys: "scheduling_user" }
  end

  def with_list(lists: [ LIST ], entries: [], resource: RESOURCE, **answers)
    calls = []
    defaults = { lists: ->(*) { lists }, entries: ->(*) { entries },
                 reasons: ->(type) { type == "A" ? [ { ien: 3, name: "F/U PATIENT; NO SCHEDULE YET" } ] : [ { ien: 5, name: "APPOINTMENT MADE" } ] },
                 add: ->(**) { { success: true, ien: 1 } }, update: ->(**) { { success: true } }, remove: ->(**) { { success: true } } }
    restores = defaults.merge(answers).map do |name, answer|
      restore = StubHelpers.send(:singleton_method_restore, RpmsRpc::WaitList, name)
      RpmsRpc::WaitList.define_singleton_method(name) do |*args, **kwargs|
        calls << [ name, kwargs ]
        kwargs.empty? ? answer.call(*args) : answer.call(*args, **kwargs)
      end
      restore
    end
    restores << StubHelpers.send(:singleton_method_restore, RpmsRpc::Scheduling, :resources)
    RpmsRpc::Scheduling.define_singleton_method(:resources) { |*| [ resource ] }
    restores << StubHelpers.send(:singleton_method_restore, RpmsRpc::SchedulingSetup, :clinic_rules)
    RpmsRpc::SchedulingSetup.define_singleton_method(:clinic_rules) { |*| nil }
    yield calls
  ensure
    restores&.each(&:call)
  end

  def sent(calls, name) = calls.select { |call| call.first == name }

  test "S-SCH-10.1 the entry goes to RPMS with what the scheduler gave" do
    sign_in
    with_list do |calls|
      post BASE, params: { wait_list: { patient_dfn: 3, added_on: "2027-01-06", reason_ien: 3, priority: "1", recall_on: "2027-02-01" } }

      assert_redirected_to BASE
      assert_equal({ list: 9, patient_dfn: 3, added_on: DAY, reason: 3, recall_on: Date.new(2027, 2, 1), priority: "1", provider: nil },
                   sent(calls, :add).sole[1])
    end
  end

  test "S-SCH-10.2 no patient, date added, reason or recall date is refused and nothing is filed" do
    sign_in
    with_list do |calls|
      post BASE, params: { wait_list: { priority: "1" } }

      assert_response :unprocessable_content
      %w[Patient Added on Reason Recall].each { |word| assert_select "#wait-list-errors", text: /#{word}/ }
      assert_empty sent(calls, :add)
    end
  end

  test "S-SCH-10.3 an inactive list offers no way to add, and refuses one" do
    sign_in
    with_list(lists: [ LIST.merge(inactive: true) ]) do |calls|
      get BASE
      assert_select "#wait-list-inactive"
      assert_select "#add-to-wait-list", 0

      post BASE, params: { wait_list: { patient_dfn: 3, added_on: "2027-01-06", reason_ien: 3, recall_on: "2027-02-01" } }
      assert_redirected_to BASE
      assert_empty sent(calls, :add)
    end
  end

  test "a clinic with no wait list says so" do
    sign_in
    with_list(lists: []) do
      get BASE

      assert_select "#no-wait-list"
    end
  end

  test "S-SCH-10.4 an open entry's change is sent and it stays open" do
    sign_in
    with_list(entries: [ entry(4, DAY) ]) do |calls|
      post "#{BASE}/4", params: { wait_list: { reason_ien: 3, priority: "3", recall_on: "2027-03-01" } }

      assert_redirected_to BASE
      assert_equal({ list: 9, entry: 4, reason: 3, recall_on: Date.new(2027, 3, 1), priority: "3", provider: nil }, sent(calls, :update).sole[1])
      assert_empty sent(calls, :remove)
    end
  end

  test "S-SCH-10.5 a removal sends its date and resolution" do
    sign_in
    with_list(entries: [ entry(4, DAY) ]) do |calls|
      post "#{BASE}/4/removal", params: { removal: { removed_on: "2027-01-06", resolution_ien: 5 } }

      assert_redirected_to BASE
      assert_equal({ list: 9, entry: 4, removed_on: DAY, resolution: 5 }, sent(calls, :remove).sole[1])
    end
  end

  test "S-SCH-10.6 a removal without a date or a resolution is refused and the entry stays open" do
    sign_in
    with_list(entries: [ entry(4, DAY) ]) do |calls|
      post "#{BASE}/4/removal", params: { removal: { removed_on: "", resolution_ien: "" } }

      assert_response :unprocessable_content
      assert_select "#wait-list-errors", text: /Removed on/
      assert_empty sent(calls, :remove)
    end
  end

  test "S-SCH-10.8 a closed entry can be read and edited, not removed or booked" do
    sign_in
    with_list(entries: [ entry(4, DAY, open: false) ]) do |calls|
      get BASE, params: { open: "0" }
      assert_select "#wait-list tr[data-entry='4'] a", text: "Edit"
      assert_select "[data-remove-entry]", 0
      assert_select "[data-book-entry]", 0

      post "#{BASE}/4/removal", params: { removal: { removed_on: "2027-01-06", resolution_ien: 5 } }
      assert_response :redirect
      post "#{BASE}/4/booking", params: { booking: { start: "2027-01-06T09:00", length: "15" } }
      assert_response :redirect
      assert_empty sent(calls, :remove)
    end
  end

  test "S-SCH-10.9 one clinic's open entries in a recall range, by recall date then priority" do
    sign_in
    rows = [ entry(1, DAY + 5, priority: "2"), entry(2, DAY + 5, priority: "1"), entry(3, DAY + 1),
             entry(4, DAY + 2, open: false), entry(5, DAY + 40) ]
    with_list(entries: rows) do
      get BASE, params: { from: DAY.iso8601, to: (DAY + 10).iso8601 }

      assert_equal %w[3 2 1], css_select("#wait-list tbody tr").map { |tr| tr["data-entry"] }
    end
  end

  test "a scheduler who may only look at the clinic sees the list and cannot change it" do
    sign_in
    with_list(entries: [ entry(4, DAY) ], resource: LOOK_ONLY) do |calls|
      get BASE
      assert_select "#wait-list tr[data-entry='4']"
      assert_select "#wait-list tr[data-entry='4'] a", 0

      post BASE, params: { wait_list: { patient_dfn: 3, added_on: "2027-01-06", reason_ien: 3, recall_on: "2027-02-01" } }
      assert_response :forbidden
      assert_empty sent(calls, :add)
    end
  end
end
