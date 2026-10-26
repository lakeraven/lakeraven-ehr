# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: counter storage must stay bounded; refused hits must not
# mint keys; expired keys must be swept; saturated counters must not be evicted.
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

  test "F1 flooding many client IPs drives key_count to max_keys" do
    mod = rate_limit_module!
    assert_respond_to mod, :key_count, "Lakeraven::EHR::RateLimit must expose .key_count (#498)"
    assert configure_for_test_accepts_max_keys?(mod),
           "#{RateLimitTestHelper::RATE_LIMIT_CONSTANT} must accept max_keys: in configure_for_test! (#498)"
    max_keys = 8
    mod.configure_for_test!(max_requests: 5, window: 10.minutes, max_keys: max_keys)

    200.times do |attempt|
      break if mod.key_count >= max_keys

      ip = "203.0.113.#{attempt % 250}"
      get "/lakeraven-ehr/Patient/1", headers: mint_token,
          env: integration_request_env(remote_addr: ip)
    end

    assert_equal max_keys, mod.key_count,
                 "key_count must reach max_keys from many distinct client IPs (#498 F1); " \
                 "saw #{mod.key_count}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "F1 evicting a saturated identity must not reopen its counter" do
    mod = rate_limit_module!
    mod.configure_for_test!(max_requests: 1, window: 10.minutes, max_keys: 2)

    assert mod.permit?(identity: "access:victim", ip: "203.0.113.10")
    refute mod.permit?(identity: "access:victim", ip: "203.0.113.10"),
           "identity must be saturated (#498 F1)"

    assert mod.permit?(identity: "access:other-b", ip: "203.0.113.11")
    assert mod.permit?(identity: "access:other-c", ip: "203.0.113.12")

    refute mod.permit?(identity: "access:victim", ip: "203.0.113.13"),
           "saturated identity must stay refused after eviction pressure (#498 F1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "F1 evicting a saturated IP must not reopen its counter" do
    mod = rate_limit_module!
    mod.configure_for_test!(max_requests: 1, window: 10.minutes, max_keys: 2)
    saturated_ip = "198.51.100.60"

    assert mod.permit?(identity: "bearer:one", ip: saturated_ip)
    refute mod.permit?(identity: "bearer:two", ip: saturated_ip),
           "IP must be saturated (#498 F1)"

    assert mod.permit?(identity: "bearer:three", ip: "198.51.100.61")
    assert mod.permit?(identity: "bearer:four", ip: "198.51.100.62")

    refute mod.permit?(identity: "bearer:five", ip: saturated_ip),
           "saturated IP must stay refused after eviction pressure (#498 F1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "F1 eviction prefers live keys with the fewest hits" do
    mod = rate_limit_module!
    mod.configure_for_test!(max_requests: 3, window: 10.minutes, max_keys: 2)

    3.times do
      assert mod.permit?(identity: nil, ip: "198.51.100.1"),
             "heavy IP bucket should admit hits under the limit (#498 F1)"
    end
    assert mod.permit?(identity: nil, ip: "198.51.100.2")
    assert mod.permit?(identity: nil, ip: "198.51.100.3")

    refute mod.permit?(identity: nil, ip: "198.51.100.1"),
           "the heavy live bucket must not be reset by evicting a lighter key (#498 F1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "F1 when every live key is saturated and the table is full new identities fail closed" do
    mod = rate_limit_module!
    mod.configure_for_test!(max_requests: 1, window: 10.minutes, max_keys: 2)

    assert mod.permit?(identity: "bearer:one", ip: "198.51.100.70")
    assert mod.permit?(identity: "bearer:two", ip: "198.51.100.71")
    assert_equal 2, mod.key_count

    refute mod.permit?(identity: "bearer:one", ip: "198.51.100.70"),
           "saturated pair must keep refusing (#498 F1)"
    refute mod.permit?(identity: "bearer:three", ip: "198.51.100.72"),
           "must fail closed when no evictable key exists (#498 F1)"
    assert_operator mod.key_count, :<=, 2
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

  def mint_token
    app = Doorkeeper::Application.create!(
      name: "rl-mem-#{SecureRandom.hex(3)}", redirect_uri: "https://example.test/cb",
      scopes: "system/Patient.read system/*.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: "system/Patient.read system/*.read", expires_in: 3600
    )
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end
end
