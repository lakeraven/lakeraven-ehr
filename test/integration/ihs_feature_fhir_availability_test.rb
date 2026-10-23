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
    fake = FakeBroker.new
    with_restricted_backend(client: fake) do
      get "/lakeraven-ehr/ServiceRequest", params: { patient: PATIENT_DFN }, headers: @headers
      assert_fhir_feature_unavailable(response, capability: :prc_referrals)
      assert_empty fake.calls
    end
  end

  test "GET Immunization returns not-supported without ihs_immunization and makes no broker call" do
    fake = FakeBroker.new
    with_restricted_backend(client: fake) do
      get "/lakeraven-ehr/Immunization", params: { patient: PATIENT_DFN }, headers: @headers
      assert_fhir_feature_unavailable(response, capability: :ihs_immunization)
      assert_empty fake.calls
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
