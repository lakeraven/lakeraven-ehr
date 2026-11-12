# frozen_string_literal: true

require "test_helper"

# rpms-ux S-SCH-17 and S-SCH-18: a scheduling supervisor keeps the access types
# and resource groups of scheduling's table maintenance. RPMS is stood in for at
# the gem boundary with the shapes a live rpms-ydb 7d0e827 build answered; the
# live test proves the same against a container.
class SchedulingTablesTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  DAY = Date.new(2027, 1, 5)

  def at(hour, min = 0) = Time.new(DAY.year, DAY.month, DAY.day, hour, min)

  RESOURCES = [
    { id: 1, name: "DEMO PRIMARY CARE", inactive: false, time_scale: 15, hospital_location_id: 6,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true },
    { id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
      view: true, overbook: true, modify_schedule: true, modify_appointments: true },
    { id: 5, name: "DEMO PODIATRY", inactive: false, time_scale: 30, hospital_location_id: 11,
      view: false, overbook: false, modify_schedule: false, modify_appointments: false }
  ].freeze

  TYPES = [ { id: 1, name: "DEMO GENERAL", inactive: false, prevent_access: false, color: "#270BF4" },
            { id: 4, name: "DEMO BLOCKED", inactive: false, prevent_access: true, color: "#808080" } ].freeze

  GROUP = { id: 2, name: "PROBE GROUP", inactive_date: nil,
            resources: [ { id: 2, resource_id: 2, name: "DEMO IHS CLINIC" }, { id: 1, resource_id: 1, name: "DEMO PRIMARY CARE" } ] }.freeze

  def sign_in(keys)
    post "/lakeraven-ehr/test_session", params: { duz: "4", user_type: "user", user_name: "MANAGER,SYSTEM", security_keys: keys }
  end

  # Stands in for the gem; records each table write.
  def with_rpms(save_type: ->(_args) { { success: true, id: 6 } }, groups: [ GROUP ])
    @writes = []
    log = @writes
    eight, noon, nine, nine15 = at(8), at(12), at(9), at(9, 15)
    stubs = {
      RpmsRpc::Scheduling.singleton_class => {
        resources: ->(*) { RESOURCES },
        slot_schedule: ->(resource:, **) { [ { start_time: eight, end_time: noon, slots: 2, access_type_id: 1, resource: resource } ] },
        appointments: ->(resource:, **) { resource == "DEMO IHS CLINIC" ? [ { id: 40, start_time: nine, end_time: nine15, patient_dfn: 3, patient_name: "MOUSE,MICKEY M", cancelled: false } ] : [] }
      },
      RpmsRpc::SchedulingMaintenance.singleton_class => {
        save_access_type: ->(**args) { log << [ :access_type, args ]; save_type.call(args) },
        save_resource_group: ->(**args) { log << [ :group, args ]; { success: true, id: 3 } },
        add_resource_group_member: ->(**args) { log << [ :add, args ]; { success: true, id: 4 } },
        remove_resource_group_member: ->(**args) { log << [ :remove, args ]; { success: true } }
      }
    }.merge(scheduling_setup_stubs(access_types: TYPES))
    stubs[RpmsRpc::SchedulingSetup.singleton_class][:resource_groups] = ->(*) { groups }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    yield
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def writes = @writes || []

  test "S-SCH-17.1 the supervisor adds an access type that prevents access, with its colour" do
    sign_in("scheduling_supervisor")
    with_rpms do
      get "/lakeraven-ehr/scheduling/access_types"
      assert_select "#access-types tr[data-access-type='4'] td[data-prevent-access='true']"

      post "/lakeraven-ehr/scheduling/access_types", params: { access_type: { name: "Lunch", color: "#cc3300", prevent_access: "1", inactive: "0" } }
      assert_redirected_to "/lakeraven-ehr/scheduling/access_types"
    end

    assert_equal [ [ :access_type, { id: nil, name: "LUNCH", inactive: false, prevent_access: true, color: "#CC3300" } ] ], writes
  end

  test "S-SCH-17.3 an access type is marked inactive on its own entry" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/access_types/1", params: { access_type: { name: "DEMO GENERAL", color: "#270BF4", prevent_access: "0", inactive: "1" } }
      assert_redirected_to "/lakeraven-ehr/scheduling/access_types"
    end

    assert_equal [ [ :access_type, { id: 1, name: "DEMO GENERAL", inactive: true, prevent_access: false, color: "#270BF4" } ] ], writes
  end

  test "S-SCH-17.4 a name too short is refused here, and RPMS's refusal of a second name is shown" do
    sign_in("scheduling_supervisor")
    duplicate = ->(_args) { { success: false, error: "BSDX14: Cannot have two Access Types with the same name." } }
    with_rpms(save_type: duplicate) do
      post "/lakeraven-ehr/scheduling/access_types", params: { access_type: { name: "LU", color: "#cc3300" } }
      assert_response :unprocessable_content
      assert_select "#access-type-errors", text: /Name/
      assert_empty writes

      post "/lakeraven-ehr/scheduling/access_types", params: { access_type: { name: "DEMO GENERAL", color: "#cc3300" } }
      assert_response :unprocessable_content
      assert_select "#access-type-alert", text: /Cannot have two Access Types with the same name/
    end
  end

  test "S-SCH-17.5 a scheduler without SDZSUP cannot list or change access types" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling"
      assert_select "#access-types-link", count: 0
      get "/lakeraven-ehr/scheduling/access_types"
      assert_response :forbidden
      post "/lakeraven-ehr/scheduling/access_types", params: { access_type: { name: "LUNCH", color: "#cc3300" } }
      assert_response :forbidden
    end

    assert_empty writes
  end

  test "S-SCH-18.1 the supervisor makes a group and adds a clinic to it" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/resource_groups", params: { name: "Front desk" }
      assert_redirected_to "/lakeraven-ehr/scheduling/resource_groups/3"

      post "/lakeraven-ehr/scheduling/resource_groups/2/members", params: { resource_id: "5" }
      assert_redirected_to "/lakeraven-ehr/scheduling/resource_groups/2"
    end

    assert_equal [ [ :group, { id: nil, name: "FRONT DESK" } ], [ :add, { group_id: 2, resource_id: "5" } ] ], writes
  end

  test "S-SCH-18.2 a group of two clinics shows both clinics' days side by side" do
    sign_in("scheduling_user")
    with_rpms do
      get "/lakeraven-ehr/scheduling/resource_groups/2", params: { date: DAY.iso8601 }

      assert_response :ok
      assert_select "#group-days section[data-group-day]", count: 2
      assert_select "#group-days section[data-group-day='2'] li[data-appointment='40']", text: /09:00, MOUSE,MICKEY M/
      assert_select "#group-days section[data-group-day='1'] li[data-block='08:00']", text: /DEMO GENERAL/
      assert_select "#group-members", count: 0
    end
  end

  test "S-SCH-18.3 the supervisor takes a clinic out of a group by its entry" do
    sign_in("scheduling_supervisor")
    with_rpms do
      post "/lakeraven-ehr/scheduling/resource_groups/2/members/1/remove"
      assert_redirected_to "/lakeraven-ehr/scheduling/resource_groups/2"
    end

    assert_equal [ [ :remove, { group_id: 2, item_id: "1" } ] ], writes
  end
end
