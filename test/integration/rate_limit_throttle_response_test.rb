# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: throttled FHIR reads, patient search, and backend-services
# token issuance return 429 with Retry-After and emit AuditEvent rows.
class RateLimitThrottleResponseTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper

  TOKEN_URL = "/lakeraven-ehr/oauth/token"

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
    Lakeraven::EHR::LoginThrottle.reset!
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "a throttled FHIR read returns 429 with Retry-After and is audited" do
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
    limit = 2

    with_test_rate_limit(max_requests: limit) do
      limit.times { get "/lakeraven-ehr/Patient/1", headers: @headers }
      Lakeraven::EHR::AuditEvent.delete_all

      get "/lakeraven-ehr/Patient/1", headers: @headers

      assert_response :too_many_requests, "FHIR read must be rate limited (#498)"
      assert_positive_retry_after!(response)
      assert_throttle_audit_event!
    end
  end

  test "a throttled patient search returns 429 with Retry-After and is audited" do
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
    limit = 2

    with_test_rate_limit(max_requests: limit) do
      limit.times do
        get "/lakeraven-ehr/Patient", params: { name: "Anderson" }, headers: @headers
      end
      Lakeraven::EHR::AuditEvent.delete_all

      get "/lakeraven-ehr/Patient", params: { name: "Anderson" }, headers: @headers

      assert_response :too_many_requests, "patient search must be rate limited (#498)"
      assert_positive_retry_after!(response)
      assert_throttle_audit_event!
    end
  end

  test "a throttled backend-services token request returns 429 with Retry-After and is audited" do
    limit = 2
    body = {
      grant_type: "client_credentials",
      client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      client_assertion: "not-a-jwt",
      scope: "system/*.read"
    }

    with_test_rate_limit(max_requests: limit) do
      limit.times { post TOKEN_URL, params: body }
      Lakeraven::EHR::AuditEvent.delete_all

      post TOKEN_URL, params: body

      assert_response :too_many_requests,
                       "SMART backend-services token endpoint must be rate limited (#498)"
      assert_positive_retry_after!(response)
      assert_throttle_audit_event!
    end
  end
end
