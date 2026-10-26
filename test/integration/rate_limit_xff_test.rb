# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: client IP must be the right-most untrusted address, never a
# spoofed left-most X-Forwarded-For entry.
class RateLimitXffTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper

  LOGIN = "/lakeraven-ehr/login"
  FHIR_READ = "/lakeraven-ehr/Patient/1"

  setup do
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
    Lakeraven::EHR::LoginThrottle.reset!
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "RateLimit IP limb ignores rotating X-Forwarded-For when REMOTE_ADDR is a public direct client" do
    limit = 2
    remote = "8.8.8.8"

    with_explicit_trusted_proxies do
      with_test_rate_limit(max_requests: limit) do
        first_three_statuses = []

        50.times do |i|
          get FHIR_READ,
              headers: rotating_bearer_headers,
              env: integration_request_env(
                remote_addr: remote,
                x_forwarded_for: rotating_spoof_xff_ip
              )
          first_three_statuses << response.status if i < 3
        end

        assert_includes first_three_statuses, 429,
                        "IP limb must throttle on REMOTE_ADDR #{remote} within the first 3 requests " \
                        "even when each request rotates Authorization and X-Forwarded-For (#498); " \
                        "saw #{first_three_statuses.inspect}"
      end
    end
  end

  test "RateLimit IP limb ignores rotating X-Forwarded-For when REMOTE_ADDR is a private direct client" do
    limit = 2
    remote = "10.1.2.3"

    with_explicit_trusted_proxies do
      with_test_rate_limit(max_requests: limit) do
        first_three_statuses = []

        50.times do |i|
          get FHIR_READ,
              headers: rotating_bearer_headers,
              env: integration_request_env(
                remote_addr: remote,
                x_forwarded_for: rotating_spoof_xff_ip
              )
          first_three_statuses << response.status if i < 3
        end

        assert_includes first_three_statuses, 429,
                        "throttle must not be bypassable by client-supplied X-Forwarded-For when " \
                        "REMOTE_ADDR #{remote} is not a configured trusted proxy (#498); " \
                        "saw #{first_three_statuses.inspect}"
      end
    end
  end

  test "RateLimit keys the IP limb on the client behind a trusted proxy via X-Forwarded-For" do
    limit = 1
    trusted_proxy = "10.0.0.5"
    first_client = "203.0.113.7"
    second_client = "203.0.113.8"

    with_explicit_trusted_proxies(trusted_proxy) do
      with_test_rate_limit(max_requests: limit) do
        get FHIR_READ,
            headers: @headers,
            env: integration_request_env(
              remote_addr: trusted_proxy,
              x_forwarded_for: first_client
            )
        refute_equal 429, response.status,
                      "first request for #{first_client} should succeed (#498)"

        get FHIR_READ,
            headers: @headers,
            env: integration_request_env(
              remote_addr: trusted_proxy,
              x_forwarded_for: first_client
            )
        assert_response :too_many_requests,
                         "second request for the same client IP must throttle (#498)"

        get FHIR_READ,
            headers: @headers,
            env: integration_request_env(
              remote_addr: trusted_proxy,
              x_forwarded_for: second_client
            )
        refute_equal 429, response.status,
                      "a different client in X-Forwarded-For must not share the first client's bucket (#498)"
      end
    end
  end

  test "LoginThrottle IP limb ignores spoofed X-Forwarded-For when REMOTE_ADDR is not trusted" do
    attempts = Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS
    remote = "8.8.8.8"

    with_explicit_trusted_proxies do
      attempts.times do |i|
        post LOGIN,
             params: { username: "user-#{i}", password: "wrong" },
             env: integration_request_env(
               remote_addr: remote,
               x_forwarded_for: "203.0.113.#{i + 1}"
             )
      end

      post LOGIN,
           params: { username: "another-user", password: "wrong" },
           env: integration_request_env(
             remote_addr: remote,
             x_forwarded_for: "203.0.113.99"
           )

      assert_response :too_many_requests,
                       "sign-in must throttle on REMOTE_ADDR, not spoofed XFF (#498)"
    end
  end

  test "LoginThrottle keys the IP limb on the client behind a trusted proxy" do
    trusted_proxy = "10.0.0.5"
    first_client = "203.0.113.7"
    second_client = "203.0.113.8"

    with_explicit_trusted_proxies(trusted_proxy) do
      Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS.times do |i|
        post LOGIN,
             params: { username: "acct-#{i}", password: "wrong" },
             env: integration_request_env(
               remote_addr: trusted_proxy,
               x_forwarded_for: first_client
             )
      end
      post LOGIN,
           params: { username: "acct-over", password: "wrong" },
           env: integration_request_env(
             remote_addr: trusted_proxy,
             x_forwarded_for: first_client
           )
      assert_response :too_many_requests,
                       "first client #{first_client} must throttle behind trusted proxy (#498)"

      post LOGIN,
           params: { username: "other-client", password: "wrong" },
           env: integration_request_env(
             remote_addr: trusted_proxy,
             x_forwarded_for: second_client
           )
      refute_equal 429, response.status,
                    "second client #{second_client} must not inherit the first client's IP throttle (#498)"
    end
  end

  private

  # Rails' default trusted-proxy list includes all private networks, so
  # REMOTE_ADDR=10.x would be treated as a proxy and X-Forwarded-For would
  # become the throttle key. Pin the set for these tests: only loopback and
  # any explicitly passed lab proxy may strip X-Forwarded-For; every other
  # REMOTE_ADDR is the client.
  def with_explicit_trusted_proxies(*extra_proxies)
    original = Rails.application.config.action_dispatch.trusted_proxies
    loopback = ActionDispatch::RemoteIp::TRUSTED_PROXIES.select do |proxy|
      proxy === "127.0.0.1" || proxy === "::1"
    end
    Rails.application.config.action_dispatch.trusted_proxies = loopback + extra_proxies.map { |ip| IPAddr.new(ip) }
    yield
  ensure
    Rails.application.config.action_dispatch.trusted_proxies = original
  end

  def rotating_bearer_headers
    { "Authorization" => "Bearer #{SecureRandom.hex(16)}" }
  end

  def rotating_spoof_xff_ip
    "198.18.#{SecureRandom.random_number(256)}.#{SecureRandom.random_number(256)}"
  end
end
