# frozen_string_literal: true

require "test_helper"

class ChartCcdAvailabilityTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    setup_smart_auth(scopes: "system/*.read")
    @service = Lakeraven::EHR::PatientDataService.new("1")
    @service.define_singleton_method(:phr_available?) { true }
  end

  teardown do
    teardown_smart_auth
  end

  test "the HTML chart says CCDs are unavailable when the actual RPC API raises an M error" do
    with_ccd_read(error: RpmsRpc::Client::RpcMError.new("MAGSIXG1 SYNTHETIC_PRIVATE_DETAIL")) do |calls|
      travel_to Time.zone.local(2026, 11, 14, 12) do
        get "/lakeraven-ehr/patients/1", headers: @headers
      end

      assert_response :ok
      assert_equal [ %w[1 3251114 3261114] ], calls
    end

    assert_select "#ccd-unavailable[role='status']", text: "CCD documents are not available on this system."
    assert_includes response.body, "Alice Anderson"
    refute_includes response.body, "MAGSIXG1"
    refute_includes response.body, "SYNTHETIC_PRIVATE_DETAIL"
  end

  test "a successful empty read does not claim CCDs are unavailable" do
    with_ccd_read do |calls|
      get "/lakeraven-ehr/patients/1", headers: @headers

      assert_response :ok
      assert_equal 1, calls.length
      assert_select "#ccd-unavailable", count: 0
    end
  end

  test "successful CCD API rows are not rendered outside the filtered chart bundle" do
    documents = [ { ien: 42, title: "SYNTHETIC_PRIVATE_CCD_TITLE", content: "SYNTHETIC_PRIVATE_CCD_BODY" } ]

    with_recording_stub(Lakeraven::EHR::PatientDataService, :new, @service) do |calls|
      with_stub(RpmsRpc::Phr, :for_patient, documents) do
        get "/lakeraven-ehr/patients/1", headers: @headers
      end

      assert_equal [ { args: [ "1" ], kwargs: {} } ], calls
    end

    assert_response :ok
    assert_select "#ccd-unavailable", count: 0
    refute_includes response.body, "SYNTHETIC_PRIVATE_CCD_TITLE"
    refute_includes response.body, "SYNTHETIC_PRIVATE_CCD_BODY"
  end

  test "FHIR chart representations do not make the HTML-only CCD read" do
    with_ccd_read do |calls|
      get "/lakeraven-ehr/patients/1.json", headers: @headers
      assert_response :ok
      assert_equal "Bundle", JSON.parse(response.body)["resourceType"]

      get "/lakeraven-ehr/patients/1", headers: @headers.merge("Accept" => "application/fhir+json")
      assert_response :ok
      assert_equal "application/fhir+json", response.media_type
      assert_empty calls
    end
  end

  test "Patient scope alone does not authorize a CCD read" do
    setup_smart_auth(scopes: "system/Patient.read")

    with_ccd_read do |calls|
      get "/lakeraven-ehr/patients/1", headers: @headers

      assert_response :ok
      assert_empty calls
      assert_select "#ccd-unavailable", count: 0
    end
  end

  test "an unauthenticated request does not make a CCD read" do
    with_ccd_read do |calls|
      get "/lakeraven-ehr/patients/1"

      assert_response :unauthorized
      assert_empty calls
    end
  end

  test "refused egress does not make a CCD read" do
    with_ccd_read do |calls|
      with_stub(Lakeraven::EHR::Part2EgressFilter, :call, nil) do
        get "/lakeraven-ehr/patients/1", headers: @headers
      end

      assert_response :service_unavailable
      assert_empty calls
      assert_select "#ccd-unavailable", count: 0
    end
  end

  test "disabled PHR keeps the chart available without making a CCD read" do
    @service = Lakeraven::EHR::PatientDataService.new("1")

    with_ccd_read do |calls|
      get "/lakeraven-ehr/patients/1", headers: @headers

      assert_response :ok
      assert_empty calls
      assert_select "#ccd-unavailable", count: 0
    end
  end

  private

  # Exercise the real service, Phr API and date mapping. Only this RPC's
  # broker reply is controlled; every other chart read uses the normal mock.
  def with_ccd_read(error: nil)
    client = RpmsRpc.client
    original = client.method(:call_rpc)
    calls = []
    restore = StubHelpers.install_singleton_stub(client, :call_rpc, nil)
    client.define_singleton_method(:call_rpc) do |rpc_name, *params|
      next original.call(rpc_name, *params) unless rpc_name == "BEHOCIR1 GETCCDS"

      calls << params
      raise error if error

      ""
    end

    with_stub(Lakeraven::EHR::PatientDataService, :new, @service) { yield calls }
  ensure
    restore&.call
  end
end
