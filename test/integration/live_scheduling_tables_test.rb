# frozen_string_literal: true

require "test_helper"
require_relative "../support/live_scheduling_readback"

# Live (rpms-ux S-SCH-17, S-SCH-18, lakeraven-ehr#985): the development
# operator, who holds SDZSUP, adds an access type that prevents access and a
# two-clinic resource group through the screens; each is read back from BSDX
# ACCESS TYPE (#9002018.35) or BSDX RESOURCE GROUP (#9002018.2) with DDR LISTER,
# and a block of the new type refuses a booking. It WRITES, so it runs only
# against a throwaway container and only when asked twice. Names carry the
# time, so a rerun adds its own rows.
#
#   LIVE_RPMS=1 LIVE_RPMS_WRITES=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9146 \
#   LIVE_RPMS_ACCESS=PSCH123 LIVE_RPMS_VERIFY='PSCH123!!' \
#   bin/rails test test/integration/live_scheduling_tables_test.rb
class LiveSchedulingTablesTest < ActionDispatch::IntegrationTest
  include LiveSchedulingReadback

  CLINIC = "DEMO PODIATRY"

  setup do
    skip "live writes: set LIVE_RPMS=1 and LIVE_RPMS_WRITES=1 against a throwaway container" unless
      defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1"
    Lakeraven::EHR::LoginThrottle.reset!
    post "/lakeraven-ehr/login", params: { username: "SYS123", password: "RPMS.000" }
    @stamp = Time.now.strftime("%H%M%S")
  end

  teardown { LiveRpmsSession.sign_on! if defined?(LIVE_RPMS) && LIVE_RPMS && ENV["LIVE_RPMS_WRITES"] == "1" }

  test "S-SCH-17.1 and 17.2 a Lunch access type that prevents access is filed, and a block of it refuses a booking" do
    name = "LUNCH #{@stamp}"
    post "/lakeraven-ehr/scheduling/access_types", params: { access_type: { name: name, color: "#cc3300", prevent_access: "1", inactive: "0" } }
    assert_response :redirect, flash[:alert].to_s

    type = RpmsRpc::SchedulingSetup.access_types.find { |t| t[:name] == name }
    assert type, "BSDX ACCESS TYPE holds #{name}"
    assert_equal [ true, false, "#CC3300" ], type.values_at(:prevent_access, :inactive, :color)

    clinic = clinic_path(CLINIC)
    resource = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }
    day = weekday_ahead(from: 20, spread: 30)
    block = RpmsRpc::Scheduling.add_availability(resource: CLINIC, start_time: wall(day, "18:00"), end_time: wall(day, "19:00"),
                                                 slots: 2, access_type_id: type[:id])
    assert block&.dig(:success), "a #{name} block on #{CLINIC}: #{block.inspect}"

    begin
      post "#{clinic}/appointments", params: { booking: { patient_dfn: "3", start: "#{day.iso8601}T18:00", length: "30", note: "" } }
      assert_response :conflict
      assert_empty clinic_appointments(resource[:hospital_location_id], wall(day, "18:00")), "nothing is filed on #44"
    ensure
      bsdx("BSDX CANCEL AVAILABILITY", block[:availability_id].to_s)
      RpmsRpc::SchedulingMaintenance.save_access_type(id: type[:id], name: name, inactive: true, prevent_access: true, color: "#CC3300")
    end
  end

  test "S-SCH-18.1 and 18.2 a two-clinic resource group is filed and its day shows both clinics" do
    name = "GROUP #{@stamp}"
    post "/lakeraven-ehr/scheduling/resource_groups", params: { name: name }
    assert_response :redirect, flash[:alert].to_s
    group_path = response.location.sub(%r{\Ahttp://[^/]+}, "")

    two = RpmsRpc::Scheduling.resources.reject { |r| r[:inactive] }.first(2)
    two.each do |r|
      post "#{group_path}/members", params: { resource_id: r[:id].to_s }
      assert_response :redirect
    end

    group = RpmsRpc::SchedulingSetup.resource_groups.find { |g| g[:name] == name }
    assert group, "BSDX RESOURCE GROUP holds #{name}"
    assert_equal two.map { |r| r[:id] }.sort, group[:resources].map { |m| m[:resource_id] }.sort, "its RESOURCE multiple holds both clinics"

    get group_path, params: { date: weekday_ahead.iso8601 }
    assert_response :ok
    two.each { |r| assert_select "#group-days section[data-group-day='#{r[:id]}'] h2", text: r[:name] }
  end

  private

  def bsdx(rpc, *params)
    client = RpmsRpc.client
    Array(client.with_context("BSDXRPC") { client.call_rpc_global_array(rpc, *params) }).join
  end
end
