# frozen_string_literal: true

require "test_helper"

# S-SCH-16 read-only slice (#984, parent #565). A scheduling supervisor
# inspects the users and rights on one clinic resource, without changing them.
# These synthetic replies exercise the pinned gem boundary, not live RPMS.
class SchedulingClinicUsersTest < ActionDispatch::IntegrationTest
  include IhsFeatureAvailabilityTestHelper

  RESOURCE = { id: 5, name: "DEMO PODIATRY", inactive: false, time_scale: 30,
               hospital_location_id: 11, view: true, overbook: false,
               modify_schedule: false, modify_appointments: false }.freeze
  USERS = [
    { id: 90, duz: 208, name: "ZULU,SCHEDULER", overbook: false,
      modify_schedule: true, modify_appointments: false, master_overbook: false },
    { id: 12, duz: 304, name: "alpha,CLERK", overbook: true,
      modify_schedule: false, modify_appointments: true, master_overbook: false },
    { id: 32, duz: 410, name: "BETA,MANAGER", overbook: true,
      modify_schedule: true, modify_appointments: true, master_overbook: true }
  ].freeze
  PATH = "/lakeraven-ehr/scheduling/clinics/5/users"

  def sign_in(keys = "scheduling_supervisor")
    post "/lakeraven-ehr/test_session", params: {
      duz: "4", user_type: "user", user_name: "MANAGER,SYSTEM", security_keys: keys
    }
  end

  def with_directory(users: USERS, resources: [ RESOURCE ], error: nil)
    @directory_reads = []
    reads = @directory_reads
    scheduling = RpmsRpc::Scheduling.singleton_class
    setup = RpmsRpc::SchedulingSetup.singleton_class
    scheduling.alias_method :__clinic_users_resources, :resources
    setup.alias_method :__clinic_users_resource_users, :resource_users
    scheduling.define_method(:resources) { |*| resources }
    setup.define_method(:resource_users) do |resource_id|
      reads << resource_id
      raise error if error

      users
    end
    yield
  ensure
    scheduling.alias_method :resources, :__clinic_users_resources
    scheduling.remove_method :__clinic_users_resources
    setup.alias_method :resource_users, :__clinic_users_resource_users
    setup.remove_method :__clinic_users_resource_users
  end

  test "a supervisor sees users alphabetically with their four resource rights and no write controls" do
    sign_in
    with_directory do
      get PATH

      assert_response :success
      assert_select "#clinic-users tbody tr", count: 3
      assert_equal %w[12 32 90], css_select("#clinic-users tbody tr").map { |row| row["data-user"] }
      assert_select "#clinic-users tr[data-user='12']" do
        assert_select "td", text: "alpha,CLERK"
        assert_select "td[data-right='overbook']", text: "Yes"
        assert_select "td[data-right='modify_schedule']", text: "No"
        assert_select "td[data-right='modify_appointments']", text: "Yes"
        assert_select "td[data-right='master_overbook']", text: "No"
      end
      assert_select "#clinic-users tr[data-user='32'] td[data-right='master_overbook']", text: "Yes"
      assert_select "form[method='post']", count: 0
      assert_select "input[type='checkbox'], select", count: 0
    end
    # A BSDX resource is not its HOSPITAL LOCATION. Reading 11 here is wrong.
    assert_equal [ 5 ], @directory_reads
  end

  test "name search is case insensitive and preserves the query in a GET form" do
    sign_in
    with_directory do
      get PATH, params: { q: "clErK" }

      assert_response :success
      assert_select "#clinic-users tbody tr", count: 1
      assert_select "#clinic-users tr[data-user='12']", count: 1
      assert_select "form[method='get'] input[name='q'][value='clErK']", count: 1
    end
    assert_equal [ 5 ], @directory_reads
  end

  test "search treats punctuation literally rather than as a pattern" do
    sign_in
    with_directory do
      get PATH, params: { q: ".*" }

      assert_response :success
      assert_select "#clinic-users tbody tr", count: 0
      assert_select "#clinic-users-no-matches", count: 1
      assert_select "#clinic-users-empty", count: 0
    end
  end

  test "an empty successful directory is distinct from a search with no matches" do
    sign_in
    with_directory(users: []) do
      get PATH

      assert_response :success
      assert_select "#clinic-users-empty", count: 1
      assert_select "#clinic-users-no-matches", count: 0
    end
  end

  test "a missing RPMS reply is unavailable rather than an empty directory" do
    sign_in
    with_directory(users: nil) do
      get PATH

      assert_response :service_unavailable
      assert_select "#clinic-users-empty, #clinic-users-no-matches", count: 0
    end
  end

  test "a broker error is unavailable without exposing its details" do
    sign_in
    with_directory(error: RpmsRpc::Client::RpcError.new("secret broker detail 7819")) do
      get PATH

      assert_response :service_unavailable
      assert_select "#clinic-users-empty, #clinic-users-no-matches", count: 0
      assert_no_match(/secret broker detail 7819/, response.body)
    end
  end

  test "a scheduler without SDZSUP cannot read the directory even for a visible clinic" do
    sign_in("scheduling_user")
    with_directory do
      get PATH

      assert_response :forbidden
    end
    assert_empty @directory_reads
  end

  test "a registration user without scheduling capability cannot read the directory" do
    sign_in("registration_menu")
    with_directory do
      get PATH

      assert_response :forbidden
    end
    assert_empty @directory_reads
  end

  test "an unknown resource cannot cause a directory read" do
    sign_in
    with_directory(resources: []) do
      get PATH

      assert_response :not_found
    end
    assert_empty @directory_reads
  end

  test "a non-clinic resource cannot cause a directory read" do
    sign_in
    with_directory(resources: [ RESOURCE.merge(hospital_location_id: nil) ]) do
      get PATH

      assert_response :not_found
    end
    assert_empty @directory_reads
  end

  test "a backend without BPRM scheduling cannot read the directory" do
    sign_in
    with_directory do
      with_restricted_backend do
        get PATH

        assert_response :not_found
      end
    end
    assert_empty @directory_reads
  end

  test "an oversized or structured search is refused before reading the directory" do
    sign_in
    [ "a" * 101, [ "alpha" ], { name: "alpha" } ].each do |query|
      with_directory do
        get PATH, params: { q: query }

        assert_response :bad_request
      end
      assert_empty @directory_reads
    end
  end

  test "RPMS names and search terms are escaped in the HTML" do
    sign_in
    malicious_name = "<script>alert('user')</script>"
    with_directory(users: [ USERS.first.merge(name: malicious_name) ]) do
      get PATH, params: { q: "<script>" }

      assert_response :success
      assert_select "#clinic-users tbody td", text: malicious_name
      assert_select "#clinic-users script", count: 0
      assert_select "input[name='q']" do |inputs|
        assert_equal "<script>", inputs.first["value"]
      end
    end
  end
end
