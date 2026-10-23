# frozen_string_literal: true

# Shared setup for #647 — backends that lack IHS-only capabilities.
module IhsFeatureAvailabilityTestHelper
  RESTRICTED_BACKEND = :ihs_restricted_test

  def register_restricted_backend(capabilities: [], client: nil)
    client ||= FakeBroker.new
    Lakeraven::EHR::BackendRegistry.register(
      RESTRICTED_BACKEND,
      client: -> { client },
      capabilities: capabilities
    )
    Lakeraven::EHR.configuration.backend = RESTRICTED_BACKEND
    client
  end

  def with_restricted_backend(capabilities: [], client: nil)
    broker = register_restricted_backend(capabilities: capabilities, client: client)
    yield broker
  ensure
    teardown_restricted_backend
  end

  def teardown_restricted_backend
    Lakeraven::EHR::BackendRegistry.unregister(RESTRICTED_BACKEND)
    Lakeraven::EHR.configuration.backend = :rpms
  end

  def assert_feature_unavailable(capability)
    error = assert_raises(Lakeraven::EHR::FeatureUnavailable) { yield }
    assert_equal capability, error.capability
    error
  end

  def assert_fhir_feature_unavailable(response, capability:)
    assert_response :not_found
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    issue = body.fetch("issue").first
    assert_equal "not-supported", issue["code"]
    assert_match(/not available/i, issue["diagnostics"])
    assert_match(/#{capability}/, issue["diagnostics"])
  end

  def rpc_calls_since(before_length)
    RpmsRpc.client.received_calls.drop(before_length)
  end

  def assert_no_rpc_calls_since(before_length)
    assert_empty rpc_calls_since(before_length), "expected no RpmsRpc.client calls, got: #{rpc_calls_since(before_length).inspect}"
  end

  def sign_in_for_dashboard(username: "lindarodriguez", password: "test123")
    post "/lakeraven-ehr/login", params: { username: username, password: password }
    assert_equal "304", session[:duz], "expected a clinician session for dashboard/chart HTML specs"
  end
end
