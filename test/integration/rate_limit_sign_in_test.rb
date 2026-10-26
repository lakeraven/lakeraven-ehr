# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: sign-in throttling (LoginThrottle today) and audit visibility.
class RateLimitSignInTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper
  include ActiveSupport::Testing::TimeHelpers

  LOGIN = "/lakeraven-ehr/login"
  LOCKOUT_CYCLES = 3

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::AuditEvent.delete_all
  end

  teardown do
    Lakeraven::EHR::LoginThrottle.reset!
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "a throttled sign-in returns 429 with Retry-After" do
    attempts = Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS
    attempts.times { post LOGIN, params: { username: "lindarodriguez", password: "wrongwrong" } }

    post LOGIN, params: { username: "lindarodriguez", password: "wrongwrong" }

    assert_response :too_many_requests
    assert_positive_retry_after!(response)
  end

  test "each sign-in throttle event is recorded in the audit trail" do
    attempts = Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS
    attempts.times { post LOGIN, params: { username: "lindarodriguez", password: "wrongwrong" } }

    before = Lakeraven::EHR::AuditEvent.count
    post LOGIN, params: { username: "lindarodriguez", password: "wrongwrong" }
    assert_response :too_many_requests

    assert_operator Lakeraven::EHR::AuditEvent.count, :>, before,
                    "throttled sign-in must emit an AuditEvent (#498)"
    assert_throttle_audit_event!
  end

  test "repeated sign-in lockouts within a day increase Retry-After progressively" do
    attempts = Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS
    username = "lindarodriguez"
    wrong_password = "wrongwrong"
    retry_afters = []

    travel_to Time.zone.parse("2026-10-26 12:00:00") do
      LOCKOUT_CYCLES.times do |cycle|
        attempts.times { post LOGIN, params: { username: username, password: wrong_password } }
        post LOGIN, params: { username: username, password: wrong_password }
        assert_response :too_many_requests, "lockout cycle #{cycle + 1} should return 429 (#498)"
        retry_afters << response.headers["Retry-After"].to_i

        travel (retry_afters.last + 1).seconds
      end

      retry_afters.each_cons(2) do |earlier, later|
        assert_operator later, :>, earlier,
                        "each repeated lockout the same day must return a longer Retry-After than the prior " \
                        "(got #{retry_afters.inspect}; progressive backoff #498)"
      end

      post LOGIN, params: { username: username, password: "test123" }
      assert_response :redirect,
                      "a correct sign-in after the final backoff window must succeed (#498)"
    end
  end

  test "repeated sign-in lockouts leave multiple visible throttle audit rows" do
    attempts = Lakeraven::EHR::LoginThrottle::MAX_ATTEMPTS

    2.times do
      attempts.times { post LOGIN, params: { username: "lindarodriguez", password: "wrongwrong" } }
      Lakeraven::EHR::AuditEvent.delete_all
      post LOGIN, params: { username: "lindarodriguez", password: "wrongwrong" }
      assert_response :too_many_requests
      assert_throttle_audit_event!
      Lakeraven::EHR::LoginThrottle.reset!
    end
  end
end
