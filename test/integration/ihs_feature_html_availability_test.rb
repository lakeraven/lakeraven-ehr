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
      assert_select "h2", text: /Immunizations/, count: 0
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
        assert_select "h2", text: /Immunizations/
        assert_match(/immunizations could not be loaded/i, response.body)
        refute_includes response.body, "No immunizations on file."
        assert_select "#chart-immunizations h2 span", { count: 0 }, "no count when the list did not load"
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
    RpmsStandIn.answer(RpmsRpc::Encounter, :for_patient, PATIENT_DFN, with: [ KEPT_ENCOUNTER, SCHEDULED_APPT ])
    RpmsStandIn.answer(RpmsRpc::Immunization, :for_patient, PATIENT_DFN, with: [
      { ien: "9001", vaccine_display: "Synthetic COVID-19", occurrence_datetime: Time.utc(2026, 1, 10, 9, 0, 0) }
    ])
  end
end
