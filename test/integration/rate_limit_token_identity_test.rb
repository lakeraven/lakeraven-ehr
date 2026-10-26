# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: oauth/token identity limb keys on client_id (or assertion iss),
# not the full assertion string.
class RateLimitTokenIdentityTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  TOKEN_URL = "/lakeraven-ehr/oauth/token"
  CLIENT_ID = "rate-limit-client-probe"

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "token endpoint throttles by client_id across varying assertions and addresses" do
    limit = 2

    with_test_rate_limit(max_requests: limit) do
      limit.times do |i|
        post TOKEN_URL,
             params: token_params(assertion: "assertion-body-#{i}"),
             env: integration_request_env(remote_addr: "203.0.113.#{i + 1}")
        refute_equal 429, response.status,
                      "request #{i + 1} should be under the identity limit (#498)"
      end

      post TOKEN_URL,
           params: token_params(assertion: "assertion-body-final"),
           env: integration_request_env(remote_addr: "203.0.113.99")

      assert_response :too_many_requests,
                       "same client_id with new assertion and IP must hit identity throttle (#498)"
      assert_positive_retry_after!(response)
    end
  end

  private

  def token_params(assertion:)
    {
      grant_type: "client_credentials",
      client_id: CLIENT_ID,
      client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      client_assertion: assertion,
      scope: "system/*.read"
    }
  end
end
