# frozen_string_literal: true

require "test_helper"

# A caller refused on an available backend is refused the same way on a backend
# that withholds the capability (#647). The not-supported 404 is only for a
# caller who would otherwise be let in, and it still wins over the 400-class
# parameter checks.
#
# Panel finding (#659): the capability guard ran before the authorization
# callbacks a controller declares (the patient-compartment binding on
# Immunization and ServiceRequest),
# so a refusal on an available backend turned into a 404 on a restricted one.
class IhsFeatureAuthorizationBeforeUnavailableTest < ActionDispatch::IntegrationTest
  include BrokerStubbing
  include IhsFeatureAvailabilityTestHelper

  OWN_DFN = "1"
  OTHER_DFN = "999"

  COMPARTMENT_TYPES = {
    "Immunization" => :ihs_immunization,
    "ServiceRequest" => :prc_referrals
  }.freeze

  setup do
    @oauth_app = Doorkeeper::Application.create!(
      name: "authz-order", redirect_uri: "https://example.test/callback",
      scopes: "patient/*.read system/*.read system/Patient.write user/Patient.write patient/Patient.write",
      confidential: true
    )
  end

  teardown do
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
    teardown_restricted_backend
  end

  COMPARTMENT_TYPES.each do |type, capability|
    # (a) a patient-bound token naming another patient's compartment
    test "GET #{type} for another patient's compartment is a 403 on an available backend" do
      get "/lakeraven-ehr/#{type}", params: { patient: OTHER_DFN },
        headers: patient_bound_headers("patient/#{type}.read", resource_owner_id: OWN_DFN)
      assert_response :forbidden
    end

    test "GET #{type} for another patient's compartment is the same 403 on a restricted backend, not a 404" do
      before = RpmsRpc.client.received_calls.length
      with_restricted_backend do
        get "/lakeraven-ehr/#{type}", params: { patient: OTHER_DFN },
          headers: patient_bound_headers("patient/#{type}.read", resource_owner_id: OWN_DFN)
        assert_response :forbidden
        refute_match(/not available|not-supported/i, response.body)
      end
      assert_empty rpc_calls_since(before)
    end

    # (b) the same token naming its OWN compartment is let in, so it learns the capability is missing
    test "GET #{type} for the token's own compartment is the not-supported 404 on a restricted backend (#{capability})" do
      with_restricted_backend do
        get "/lakeraven-ehr/#{type}", params: { patient: OWN_DFN },
          headers: patient_bound_headers("patient/#{type}.read", resource_owner_id: OWN_DFN, accept: "application/fhir+json")
        assert_fhir_feature_unavailable(response, capability: capability)
      end
    end

    # (c) the 404 still wins over the 400-class checks, for an authorized caller
    test "GET #{type} with a bad _count for the token's own compartment is a 404, not a 400, on a restricted backend" do
      with_restricted_backend do
        get "/lakeraven-ehr/#{type}", params: { patient: OWN_DFN, _count: "invalid" },
          headers: patient_bound_headers("patient/#{type}.read", resource_owner_id: OWN_DFN, accept: "application/fhir+json")
        assert_fhir_feature_unavailable(response, capability: capability)
      end
    end

    test "GET #{type} with no patient parameter for a patient-bound token is a 404, not a 400, on a restricted backend" do
      with_restricted_backend do
        get "/lakeraven-ehr/#{type}",
          headers: patient_bound_headers("patient/#{type}.read", resource_owner_id: OWN_DFN, accept: "application/fhir+json")
        assert_fhir_feature_unavailable(response, capability: capability)
      end
    end

    # (d) no token
    test "GET #{type} for another patient's compartment with no token is a 401 on a restricted backend" do
      with_restricted_backend do
        get "/lakeraven-ehr/#{type}", params: { patient: OTHER_DFN }
        assert_response :unauthorized
        refute_match(/not available|not-supported/i, response.body)
      end
    end

    # (e) an available backend is unchanged
    test "GET #{type} for the token's own compartment is a 200 on an available backend" do
      get "/lakeraven-ehr/#{type}", params: { patient: OWN_DFN },
        headers: patient_bound_headers("patient/#{type}.read", resource_owner_id: OWN_DFN, accept: "application/fhir+json")
      assert_response :ok
    end

    test "GET #{type} with a bad _count is a 400 on an available backend" do
      get "/lakeraven-ehr/#{type}", params: { patient: OWN_DFN, _count: "invalid" },
        headers: patient_bound_headers("patient/#{type}.read", resource_owner_id: OWN_DFN, accept: "application/fhir+json")
      assert_response :bad_request
    end

    test "GET #{type} with no patient parameter is a 400 on an available backend" do
      get "/lakeraven-ehr/#{type}",
        headers: patient_bound_headers("patient/#{type}.read", resource_owner_id: OWN_DFN, accept: "application/fhir+json")
      assert_response :bad_request
    end
  end

  private

  def patient_bound_headers(scopes, resource_owner_id:, accept: nil, content_type: false)
    bearer_headers(scopes, resource_owner_id: resource_owner_id, accept: accept, content_type: content_type)
  end

  def bearer_headers(scopes, resource_owner_id: nil, accept: nil, content_type: false)
    token = Doorkeeper::AccessToken.create!(
      application: @oauth_app, scopes: scopes, resource_owner_id: resource_owner_id, expires_in: 3600
    )
    headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
    headers["Accept"] = accept if accept
    headers["Content-Type"] = "application/fhir+json" if content_type
    headers
  end
end
