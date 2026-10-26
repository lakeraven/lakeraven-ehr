# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498 F3/F6: sign-in rate limits must not leave an active session;
# sessions#create identity is the access code, not a Bearer header.
class RateLimitSignInSessionTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  LOGIN = "/lakeraven-ehr/login"
  CHART = "/lakeraven-ehr/patients/1"
  CLINICIAN = { username: "lindarodriguez", password: "test123" }.freeze

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
  end

  teardown do
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "F3 RateLimit refusal on POST login terminates an established clinician session" do
    post LOGIN, params: CLINICIAN
    assert_response :redirect
    assert_equal "304", session[:duz], "expected Linda signed in before RateLimit refusal (#498 F3)"

    with_test_rate_limit(max_requests: 0, window: 5.minutes) do
      post LOGIN, params: CLINICIAN
      assert_response :too_many_requests, "RateLimit must refuse the next sign-in (#498 F3)"
    end

    assert_nil session[:duz],
               "RateLimit refusal must clear session[:duz] (#498 F3)"
    get CHART
    refute_equal 200, response.status,
                 "throttled sign-in must not leave a chart session (#498 F3); got #{response.status}"
  end

  test "F3 LoginThrottle refusal on POST login terminates an established clinician session" do
    post LOGIN, params: CLINICIAN
    assert_response :redirect
    assert_equal "304", session[:duz]

    throttle = Lakeraven::EHR::LoginThrottle
    original = throttle.method(:throttled?)
    throttle.define_singleton_method(:throttled?) { |*_args| true }
    post LOGIN, params: CLINICIAN
    throttle.define_singleton_method(:throttled?, original)

    assert_response :too_many_requests, "LoginThrottle must refuse the next sign-in (#498 F3)"
    assert_nil session[:duz],
               "LoginThrottle refusal must clear session[:duz] (#498 F3)"
    get CHART
    refute_equal 200, response.status,
                 "LoginThrottle refusal must not leave a chart session (#498 F3); got #{response.status}"
  end

  test "F6 sign-in identity is the access code across IPs even when each request sends a junk Bearer" do
    limit = 2
    ips = %w[198.51.100.91 198.51.100.92 198.51.100.93 198.51.100.94]
    statuses = []

    with_test_rate_limit(max_requests: limit) do
      without_login_throttle_enforcement do
        ips.each_with_index do |ip, i|
          post LOGIN,
               params: CLINICIAN,
               headers: { "Authorization" => "Bearer junk-bearer-#{i}" },
               env: integration_request_env(remote_addr: ip)
          statuses << response.status
        end
      end
    end

    assert_equal [ 302, 302, 429, 429 ], statuses,
                 "sessions#create must rate-limit by access code, not Bearer (#498 F6); got #{statuses.inspect}"
  end
end
