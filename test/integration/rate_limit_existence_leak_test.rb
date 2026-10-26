# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: a throttled hit and a throttled miss are indistinguishable.
class RateLimitExistenceLeakTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "throttled responses do not leak whether the resource exists" do
    limit = 1

    with_test_rate_limit(max_requests: limit) do
      get "/lakeraven-ehr/Patient/1", headers: @headers
      assert_response :success

      get "/lakeraven-ehr/Patient/1", headers: @headers
      assert_response :too_many_requests
      existing = normalized_throttle_response(response)

      get "/lakeraven-ehr/Patient/999999", headers: @headers
      assert_response :too_many_requests
      missing = normalized_throttle_response(response)

      assert_equal existing, missing,
                   "throttled existing and missing FHIR reads must be byte-identical " \
                   "(status, headers except Date/request-id, body) (#498)"
    end
  end
end
