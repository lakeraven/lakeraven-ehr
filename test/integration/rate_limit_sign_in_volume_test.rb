# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: sessions#create must be enforced by RateLimit (IP limb), not only LoginThrottle.
class RateLimitSignInVolumeTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  LOGIN = "/lakeraven-ehr/login"

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
  end

  teardown do
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "many distinct usernames from one address are throttled on the RateLimit IP limb" do
    ip = "198.51.100.80"
    limit = 3
    attempts = Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS
    assert_operator limit, :<, attempts,
                    "RateLimit max must be below LoginThrottle MAX_ATTEMPTS so this test isolates RateLimit (#498)"

    with_test_rate_limit(max_requests: limit) do
      without_login_throttle_enforcement do
        limit.times do |i|
          post LOGIN,
               params: { username: "distinct-user-#{i}", password: "wrong" },
               env: integration_request_env(remote_addr: ip)
          refute_equal 429, response.status,
                        "attempt #{i + 1} should stay under RateLimit IP max (#498)"
        end

        post LOGIN,
             params: { username: "distinct-user-final", password: "wrong" },
             env: integration_request_env(remote_addr: ip)

        assert_response :too_many_requests,
                         "RateLimit must throttle sign-in volume on the IP limb (#498)"
        assert_positive_retry_after!(response)
      end
    end
  end
end
