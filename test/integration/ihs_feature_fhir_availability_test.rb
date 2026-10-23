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
    # The Rails test client's default Accept is browser-style (text/html;q=0.9
    # with */*;q=0.5); a FHIR client names the type it wants.
    @headers = @headers.merge("Accept" => "application/fhir+json")
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

  # Copilot round (#659): a withheld endpoint reports unavailability before any
  # search-parameter validation, so a malformed parameter cannot turn it into a 400.
  {
    "_count=invalid" => { _count: "invalid" },
    "an unsupported _sort" => { _sort: "not-a-search-parameter" },
    "an unsupported _include" => { _include: "Immunization:not-a-reference" }
  }.each do |label, extra|
    test "GET Immunization with #{label} on a restricted backend is not-supported, not a 400" do
      before = RpmsRpc.client.received_calls.length
      with_restricted_backend do
        get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN }.merge(extra), headers: @headers
        assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
      end
      assert_empty rpc_calls_since(before)
    end

    test "GET ServiceRequest with #{label} on a restricted backend is not-supported, not a 400" do
      before = RpmsRpc.client.received_calls.length
      with_restricted_backend do
        get "/lakeraven-ehr/ServiceRequest", params: { patient: PATIENT_DFN }.merge(extra), headers: @headers
        assert_fhir_feature_unavailable(response, capability: :prc_referrals)
      end
      assert_empty rpc_calls_since(before)
    end
  end

  test "an invalid _count is still a 400 where the capability is present" do
    get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN, _count: "invalid" }, headers: @headers
    assert_response :bad_request
  end

  # Only the representations this renderer can produce compete: HTML and FHIR JSON.
  # A range it cannot serve (application/xml) never decides, and a specific range
  # outranks the wildcard that also matches it.
  {
    "an unsupported range with a higher q" =>
      "application/xml;q=1, text/html;q=0.8, application/fhir+json;q=0.1, */*;q=0.01",
    "a wildcard with a higher q than an explicit FHIR JSON" =>
      "text/html;q=0.9, application/fhir+json;q=0.1, */*;q=1"
  }.each do |label, accept|
    test "feature unavailable renders HTML when HTML is the preferred supported type: #{label}" do
      with_restricted_backend do
        get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN },
          headers: @headers.merge("Accept" => accept)
        assert_response :not_found
        assert_match(/not available on this system/i, response.body)
        refute_equal "application/fhir+json", response.media_type
      end
    end
  end

  test "feature unavailable renders FHIR JSON when it outranks HTML among the supported types" do
    with_restricted_backend do
      get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN },
        headers: @headers.merge("Accept" => "application/xml;q=1, text/html;q=0.2, application/fhir+json;q=0.9, */*;q=0.5")
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  # Gate round 1 (#659): every non-blank Accept goes through the one comparator.
  # Before, a header with no comma-adjacent */* fell through to Rails' own format
  # negotiation, which ignores q=0 and quality ranking.
  {
    "a lone wildcard" => "*/*",
    "text/html refused with q=0" => "text/html;q=0",
    "text/html refused with q=0 beside FHIR JSON" => "text/html;q=0, application/fhir+json",
    "text/html refused with q=0 beside a wildcard" => "text/html;q=0, */*;q=0.5",
    "a malformed q on text/html" => "text/html;q=abc",
    "a malformed q on FHIR JSON beside text/html" => "text/html, application/fhir+json;q=oops",
    "a q above 1" => "text/html;q=5",
    "text/html and FHIR JSON named at equal quality" => "text/html, application/fhir+json"
  }.each do |label, accept|
    test "feature unavailable renders FHIR JSON for #{label}" do
      with_restricted_backend do
        get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN },
          headers: @headers.merge("Accept" => accept)
        assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
      end
    end
  end

  {
    "text/html alone" => "text/html",
    "text/html ahead of a lower FHIR JSON" => "text/html, application/fhir+json;q=0.5",
    "text/html tied with a wildcard" => "text/html, */*",
    "a type wildcard" => "text/*",
    "a browser navigation header" =>
      "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
  }.each do |label, accept|
    test "feature unavailable renders HTML for #{label}" do
      with_restricted_backend do
        get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN },
          headers: @headers.merge("Accept" => accept)
        assert_response :not_found
        assert_match(/not available on this system/i, response.body)
        refute_equal "application/fhir+json", response.media_type
      end
    end
  end

  test "feature unavailable renders FHIR JSON when Accept is blank" do
    with_restricted_backend do
      get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN },
        headers: @headers.merge("Accept" => "")
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
    end
  end

  # Gate round 1 (#659): the capability check sits AFTER authentication and scope,
  # so a withheld endpoint never answers an unauthenticated or out-of-scope caller
  # with 404/400 (which would tell them the capability is missing).
  {
    "Immunization" => :ihs_immunization,
    "ServiceRequest" => :prc_referrals
  }.each do |type, capability|
    test "GET #{type} with a bad _count on a restricted backend and no token is a 401" do
      before = RpmsRpc.client.received_calls.length
      with_restricted_backend do
        get "/lakeraven-ehr/#{type}", params: { patient: PATIENT_DFN, _count: "invalid" }
        assert_response :unauthorized
        refute_match(/not available/i, response.body)
      end
      assert_empty rpc_calls_since(before)
    end

    test "GET #{type} with a bad _count on a restricted backend and an out-of-scope token is a 403" do
      headers = headers_for_scopes("system/Patient.read")
      with_restricted_backend do
        get "/lakeraven-ehr/#{type}", params: { patient: PATIENT_DFN, _count: "invalid" }, headers: headers
        assert_response :forbidden
        refute_match(/not available/i, response.body)
      end
    end

    test "GET #{type} on a restricted backend with an in-scope token is the not-supported 404 (#{capability})" do
      with_restricted_backend do
        get "/lakeraven-ehr/#{type}", params: { patient: PATIENT_DFN, _count: "invalid" }, headers: @headers
        assert_fhir_feature_unavailable(response, capability: capability)
      end
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

  # A second, narrower token without disturbing @headers.
  def headers_for_scopes(scopes)
    saved = @headers
    setup_smart_auth(scopes: scopes)
    @headers
  ensure
    @headers = saved
  end

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
