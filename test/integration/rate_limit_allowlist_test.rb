# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: smart_launch#show must be throttled (client_id oracle).
class RateLimitAllowlistTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "smart launch is throttled and not allowlisted" do
    refute_includes reviewed_allowlist_keys, "lakeraven/ehr/smart_launch#show",
                    "smart_launch#show must not be on the reviewed allowlist (#498)"
    assert_includes throttled_route_keys, "lakeraven/ehr/smart_launch#show",
                    "smart_launch#show must be registered as throttled (#498)"

    with_test_rate_limit(max_requests: 0, window: 1.minute) do
      get "/lakeraven-ehr/smart/launch",
          params: { launch: "probe", iss: "https://ehr.example.test" },
          env: integration_request_env(remote_addr: "198.51.100.90")

      assert_response :too_many_requests,
                       "smart launch must be throttled before handler logic (#498)"
      assert_positive_retry_after!(response)
    end
  end
end
