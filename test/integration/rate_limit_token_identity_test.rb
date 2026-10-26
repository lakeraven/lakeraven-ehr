# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498 F2: oauth/token limits are IP plus (client_id, IP), not a global client limb.
class RateLimitTokenIdentityTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  TOKEN_URL = "/lakeraven-ehr/oauth/token"
  VICTIM_CLIENT = "victim-client"

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  # Since #496 an unverified assertion cannot mint tokens; a global per-client_id
  # identity limb only enables lockout DoS from any IP that can name the victim.
  test "F2 forged victim client_id from one IP does not throttle the same client_id from another IP" do
    limit = 2
    attacker_ip = "203.0.113.40"
    victim_ip = "203.0.113.41"

    with_test_rate_limit(max_requests: limit) do
      (limit + 1).times do |i|
        post TOKEN_URL,
             params: token_params(client_id: VICTIM_CLIENT, assertion_iss: VICTIM_CLIENT),
             env: integration_request_env(remote_addr: attacker_ip)
      end
      assert_response :too_many_requests,
                       "attacker IP must hit its own (client_id, IP) bucket (#498 F2)"

      post TOKEN_URL,
           params: token_params(client_id: VICTIM_CLIENT, assertion_iss: VICTIM_CLIENT),
           env: integration_request_env(remote_addr: victim_ip)

      refute_equal 429, response.status,
                    "victim client_id from a different IP must not inherit the attacker's throttle (#498 F2)"
    end
  end

  test "F2 bare client_id without assertion still keys only the caller IP pair" do
    limit = 2
    attacker_ip = "198.51.100.10"
    other_ip = "198.51.100.11"

    with_test_rate_limit(max_requests: limit) do
      limit.times do
        post TOKEN_URL,
             params: {
               grant_type: "client_credentials",
               client_id: VICTIM_CLIENT,
               scope: "system/*.read"
             },
             env: integration_request_env(remote_addr: attacker_ip)
        refute_equal 429, response.status
      end

      post TOKEN_URL,
           params: {
             grant_type: "client_credentials",
             client_id: VICTIM_CLIENT,
             scope: "system/*.read"
           },
           env: integration_request_env(remote_addr: attacker_ip)
      assert_response :too_many_requests

      post TOKEN_URL,
           params: {
             grant_type: "client_credentials",
             client_id: VICTIM_CLIENT,
             scope: "system/*.read"
           },
           env: integration_request_env(remote_addr: other_ip)

      refute_equal 429, response.status,
                    "bare client_id must not throttle every IP for that client (#498 F2)"
    end
  end

  private

  def token_params(client_id:, assertion_iss:)
    {
      grant_type: "client_credentials",
      client_id: client_id,
      client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      client_assertion: unsigned_jwt("iss" => assertion_iss),
      scope: "system/*.read"
    }
  end
end
