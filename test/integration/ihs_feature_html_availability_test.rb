# frozen_string_literal: true

require "test_helper"

# HTML surfaces for IHS-only capabilities (#647).
class IhsFeatureHtmlAvailabilityTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include IhsFeatureAvailabilityTestHelper

  PATIENT_DFN = "1"
  KEPT_ENCOUNTER = { datetime: Date.new(2026, 2, 1), location_ien: 10, location: "Stock Encounter Ward", status: "KEPT" }.freeze
  SCHEDULED_APPT = { datetime: Date.new(2026, 5, 1), location_ien: 20, location: "Scheduling Clinic Future", status: "SCHEDULED" }.freeze

  setup do
    setup_smart_auth(scopes: "system/*.read")
    seed_chart_rows
  end

  teardown do
    teardown_smart_auth
    teardown_restricted_backend
    reset_chart_rows
  end

  test "dashboard omits the Pending Referrals count without prc_referrals" do
    with_restricted_backend do
      sign_in_for_dashboard
      get "/lakeraven-ehr/dashboard"
      assert_response :ok
      refute_includes response.body, "Pending Referrals"
    end
  end

  test "chart omits the Immunizations card without ihs_immunization" do
    with_restricted_backend do
      get_chart_html
      assert_response :ok
      refute_includes response.body, ">Immunizations</h2>"
    end
  end

  test "chart keeps kept encounters and scheduled appointment rows without bprm_scheduling" do
    with_restricted_backend do
      get_chart_html
      assert_response :ok
      assert_includes response.body, "Stock Encounter Ward"
      assert_includes response.body, "Scheduling Clinic Future"
    end
  end

  test "chart Immunizations card reports a load failure instead of an empty list when the gateway raises" do
    with_restricted_backend(capabilities: [ :ihs_immunization ]) do
      with_gateway_method(Lakeraven::EHR::ImmunizationGateway, :for_patient, ->(*) { raise RpmsRpc::Client::RpcError, "broker timeout" }) do
        get_chart_html
        assert_response :ok
        assert_includes response.body, ">Immunizations</h2>"
        assert_match(/immunizations could not be loaded/i, response.body)
        refute_includes response.body, "No immunizations on file."
        refute_match(/Immunizations<\/h2><span class="count">0<\/span>/, response.body)
      end
    end
  end

  private

  def with_gateway_method(gateway, name, impl)
    singleton = gateway.singleton_class
    original = singleton.instance_method(name)
    gateway.define_singleton_method(name, impl)
    yield
  ensure
    gateway.define_singleton_method(name, original)
  end

  def get_chart_html
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: @headers
  end

  def seed_chart_rows
    RpmsRpc.client.seed_keyed_collection(:patient_appointments, PATIENT_DFN, [ KEPT_ENCOUNTER, SCHEDULED_APPT ])
    RpmsRpc.client.seed_keyed_collection(:immunization_list, "#{PATIENT_DFN}^I", [
      { record_type: "I", ien: 9001, vaccine_code: "207", vaccine_display: "Synthetic COVID-19",
        status: "completed", occurrence_datetime: Time.utc(2026, 1, 10, 9, 0, 0) }
    ])
  end

  def reset_chart_rows
    RpmsRpc.client.seed_keyed_collection(:patient_appointments, PATIENT_DFN, [])
    RpmsRpc.client.seed_keyed_collection(:immunization_list, "#{PATIENT_DFN}^I", [])
  end
end
