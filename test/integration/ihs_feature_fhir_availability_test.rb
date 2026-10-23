# frozen_string_literal: true

require "test_helper"

# FHIR surfaces for IHS-only capabilities (#647): 404 OperationOutcome not-supported,
# no backend call when the capability is absent.
class IhsFeatureFhirAvailabilityTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include BrokerStubbing
  include IhsFeatureAvailabilityTestHelper

  PATIENT_DFN = "1"

  setup do
    setup_smart_auth(scopes: "system/*.read system/Patient.write")
  end

  teardown do
    teardown_smart_auth
    teardown_restricted_backend
  end

  test "GET ServiceRequest returns not-supported without prc_referrals and makes no broker call" do
    before = RpmsRpc.client.received_calls.length
    with_restricted_backend do
      get "/lakeraven-ehr/ServiceRequest", params: { patient: PATIENT_DFN }, headers: @headers
      assert_fhir_feature_unavailable(response, capability: :prc_referrals)
      assert_no_rpc_calls_since(before)
    end
  end

  test "GET ServiceRequest on rpms records RpmsRpc.client calls so the guard assertion can fail" do
    before = RpmsRpc.client.received_calls.length
    get "/lakeraven-ehr/ServiceRequest", params: { patient: PATIENT_DFN }, headers: @headers
    assert_response :ok
    refute_empty rpc_calls_since(before), "expected ServiceRequest search to reach RpmsRpc.client on rpms"
  end

  test "GET Immunization returns not-supported without ihs_immunization and makes no broker call" do
    before = RpmsRpc.client.received_calls.length
    with_restricted_backend do
      get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN }, headers: @headers
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
      assert_no_rpc_calls_since(before)
    end
  end

  test "GET Immunization on rpms records RpmsRpc.client calls so the guard assertion can fail" do
    before = RpmsRpc.client.received_calls.length
    get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN }, headers: @headers
    assert_response :ok
    refute_empty rpc_calls_since(before), "expected Immunization search to reach RpmsRpc.client on rpms"
  end

  test "GET Immunization without patient on a restricted backend returns not-supported before param validation" do
    with_restricted_backend do
      get "/lakeraven-ehr/Immunization", headers: @headers
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  test "POST Patient returns not-supported without bprm_registration and makes no broker call" do
    fake = FakeBroker.new.on(Lakeraven::EHR::RegistrationGateway::REGISTER_RPC, "1^12345^")
    with_restricted_backend(client: fake) do
      post "/lakeraven-ehr/Patient",
        params: registration_patient_json,
        headers: fhir_write_headers
      assert_fhir_feature_unavailable(response, capability: :bprm_registration)
      assert_empty fake.calls
    end
  end

  test "GET ServiceRequest as HTML returns a not available on this system page without prc_referrals" do
    with_restricted_backend do
      get "/lakeraven-ehr/ServiceRequest",
        params: { patient: PATIENT_DFN },
        headers: @headers.merge("Accept" => "text/html")
      assert_response :not_found
      assert_match(/not available on this system/i, response.body)
      refute_equal "application/fhir+json", response.media_type
    end
  end

  test "feature unavailable prefers FHIR when Accept lists text/html with lower q than application/fhir+json" do
    with_restricted_backend do
      get "/lakeraven-ehr/Immunization",
        params: { patient: PATIENT_DFN },
        headers: @headers.merge("Accept" => "text/html;q=0.1, application/fhir+json")
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  test "chart FHIR bundle on a restricted backend includes an outcome for withheld Immunization resources" do
    with_restricted_backend do
      get "/lakeraven-ehr/patients/#{PATIENT_DFN}",
        headers: @headers.merge("Accept" => "application/fhir+json")
      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal "Bundle", body["resourceType"]
      outcomes = body.fetch("entry").select { |e| e.dig("search", "mode") == "outcome" }
      assert outcomes.any?, "expected at least one outcome entry"
      immunization_outcome = outcomes.find do |entry|
        issue = entry.dig("resource", "issue", 0)
        issue["code"] == "not-supported" && issue["diagnostics"].to_s.match?(/immunization/i)
      end
      assert immunization_outcome, "expected a not-supported outcome naming immunizations"
    end
  end

  test "chart FHIR bundle includes an exception outcome when immunization read fails with ihs_immunization" do
    raw_message = "broker timeout with sensitive internal detail"
    gateway = Lakeraven::EHR::ImmunizationGateway
    original = gateway.singleton_class.instance_method(:for_patient)
    gateway.define_singleton_method(:for_patient) { |*| raise RpmsRpc::Client::RpcError, raw_message }

    with_restricted_backend(capabilities: [ :ihs_immunization ]) do
      get "/lakeraven-ehr/patients/#{PATIENT_DFN}",
        headers: @headers.merge("Accept" => "application/fhir+json")
      assert_response :ok
      body = JSON.parse(response.body)
      outcomes = body.fetch("entry").select { |e| e.dig("search", "mode") == "outcome" }
      failure_outcome = outcomes.find do |entry|
        issue = entry.dig("resource", "issue", 0)
        issue["severity"] == "error" &&
          issue["code"] == "exception" &&
          issue["diagnostics"].to_s.match?(/immunizations could not be loaded/i)
      end
      assert failure_outcome, "expected an exception outcome for a failed immunization read"
      diagnostics = failure_outcome.dig("resource", "issue", 0, "diagnostics")
      refute_includes diagnostics, raw_message
      refute_match(/sensitive internal detail/i, diagnostics)
    end
  ensure
    gateway.define_singleton_method(:for_patient, original)
  end

  test "feature unavailable honors ?_format=json for a browser Accept header" do
    with_restricted_backend do
      get "/lakeraven-ehr/Immunization",
        params: { patient: PATIENT_DFN, _format: "json" },
        headers: @headers.merge("Accept" => "text/html,application/xhtml+xml")
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  private

  def registration_patient_json
    {
      resourceType: "Patient",
      name: [ { family: "RESTRICTED", given: [ "SYNTH" ] } ],
      gender: "female",
      birthDate: "1985-06-15"
    }.to_json
  end

  def fhir_write_headers
    @headers.merge("Content-Type" => "application/fhir+json")
  end
end
