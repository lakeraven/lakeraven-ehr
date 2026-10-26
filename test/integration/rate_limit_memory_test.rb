# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: counter storage must stay bounded; refused hits must not
# mint keys; expired keys must be swept; oldest keys evicted at a hard cap.
class RateLimitMemoryTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "refused requests with random bearers do not grow key_count by one per request" do
    ip = "198.51.100.40"
    mod = rate_limit_module!
    assert_respond_to mod, :key_count,
                      "Lakeraven::EHR::RateLimit must expose .key_count (#498)"
    mod.configure_for_test!(max_requests: 1, window: 5.minutes)
    get "/lakeraven-ehr/Patient/1", headers: @headers,
        env: integration_request_env(remote_addr: ip)
    baseline = mod.key_count

    500.times do
      headers = { "Authorization" => "Bearer #{SecureRandom.hex(16)}" }
      get "/lakeraven-ehr/Patient/1", headers: headers,
          env: integration_request_env(remote_addr: ip)
      assert_response :too_many_requests, "IP limb must refuse after max (#498)"
    end

    growth = mod.key_count - baseline
    assert_operator growth, :<, 500,
                    "refused requests must not create one counter key per random bearer (#498); " \
                    "key_count grew by #{growth}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "expired counter keys are removed after the window elapses" do
    mod = rate_limit_module!
    assert_respond_to mod, :key_count, "Lakeraven::EHR::RateLimit must expose .key_count (#498)"
    window = 2.minutes
    mod.configure_for_test!(max_requests: 5, window: window)

    travel_to Time.zone.parse("2026-10-26 12:00:00") do
      3.times do
        get "/lakeraven-ehr/Patient/1", headers: @headers,
            env: integration_request_env(remote_addr: "203.0.113.10")
        assert_response :success
      end
      assert_operator mod.key_count, :>, 0

      travel window + 1.second
      assert_respond_to mod, :sweep_expired!,
                        "Lakeraven::EHR::RateLimit must expose .sweep_expired! (#498)"
      mod.sweep_expired!

      assert_equal 0, mod.key_count,
                   "expired keys must be swept so key_count returns to zero (#498)"
    end
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "above max_keys the oldest entries are evicted and the limiter still refuses" do
    mod = rate_limit_module!
    assert_respond_to mod, :key_count, "Lakeraven::EHR::RateLimit must expose .key_count (#498)"
    assert configure_for_test_accepts_max_keys?(mod),
           "#{RateLimitTestHelper::RATE_LIMIT_CONSTANT} must accept max_keys: in configure_for_test! (#498)"
    mod.configure_for_test!(max_requests: 1, window: 10.minutes, max_keys: 3)
    ip = "198.51.100.55"

    10.times do |i|
      headers = { "Authorization" => "Bearer eviction-#{i}" }
      get "/lakeraven-ehr/Patient/1", headers: headers,
          env: integration_request_env(remote_addr: ip)
    end

    assert_operator mod.key_count, :<=, 3,
                    "key_count must respect max_keys (#498)"
    get "/lakeraven-ehr/Patient/1", headers: @headers,
        env: integration_request_env(remote_addr: ip)
    assert_response :too_many_requests,
                     "limiter must still refuse after eviction, not open the floodgates (#498)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  def configure_for_test_accepts_max_keys?(mod)
    mod.configure_for_test!(max_requests: 1, window: 1.minute, max_keys: 2)
    mod.reset!
    true
  rescue ArgumentError
    false
  end
end
