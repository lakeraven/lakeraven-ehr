# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498 H1: an identity that cannot be stored must be refused (429), never granted.
class RateLimitIdentityFailClosedTest < ActiveSupport::TestCase
  include RateLimitTestHelper

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "a bearer from fresh IPs after the table fills with light IP buckets is granted exactly max_requests times" do
    mod = rate_limit_module!
    max_requests = 3
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: 20)

    20.times do |i|
      assert mod.permit?(identity: nil, ip: "198.51.100.#{i + 1}"),
             "light IP bucket #{i + 1} must be granted (#498 H1)"
    end

    results = 30.times.map do |i|
      mod.permit?(identity: "bearer:fail-closed-probe", ip: "203.0.113.#{i + 1}")
    end

    grants = results.count(true)
    assert_equal max_requests, grants,
                 "identity must fail closed at max_keys: expected exactly #{max_requests} grants, got #{grants} (#498 H1)"
    assert_equal [ true, true, true ] + ([ false ] * 27), results,
                 "first #{max_requests} bearer probes must grant, then refuse (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "a bearer spread across many fresh IPs after a large light IP fill grants at most max_requests and at least one" do
    mod = rate_limit_module!
    max_requests = 3
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: 200)

    200.times do |i|
      assert mod.permit?(identity: nil, ip: "198.51.100.#{i + 1}"),
             "light IP bucket #{i + 1} must be granted (#498 H1)"
    end

    grants = 60.times.count do |i|
      mod.permit?(identity: "bearer:fail-closed-large", ip: "203.0.113.#{i + 1}")
    end

    assert_operator grants, :<=, max_requests,
                    "identity must not exceed max_requests when the table is full (#498 H1); grants=#{grants}"
    assert_operator grants, :>=, 1,
                    "reserved identity headroom must allow at least one grant (#498 H1); grants=#{grants}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "an identity that cannot be stored is refused, not granted" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)

    before = mod.bucket_count
    refute mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip),
           "new identity must be refused when it cannot be stored (#498 H1)"
    assert_equal before, mod.bucket_count, "refusal must not grow stored buckets (#498 H1)"

    5.times do
      refute mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip),
             "refused identity must not receive free grants while the table stays saturated (#498 H1)"
    end
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "a refused identity mints no bucket" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)

    before = mod.bucket_count
    mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip)
    assert_equal before, mod.bucket_count,
                 "refused identity must not mint an identity bucket (#498 H1)"

    assert mod.permit?(identity: nil, ip: newcomer_ip),
           "refused newcomer probe must not charge the protected IP bucket (#498 H1)"
    refute mod.permit?(identity: nil, ip: newcomer_ip),
           "newcomer IP must be at its limit after one post-refusal grant (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "nil identity is still granted on an IP with budget when identity storage is full" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)

    assert mod.permit?(identity: nil, ip: newcomer_ip),
           "IP limb must still grant when only identity storage is exhausted (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "a new identity evicts a light identity rather than being refused" do
    mod = rate_limit_module!
    max_keys = 19
    newcomer_ip = build_fail_closed_table_with_light_identity!(mod, max_keys: max_keys)

    assert_equal max_keys, mod.bucket_count, "fixture must fill the table before the probe (#498 H1)"
    assert mod.permit?(identity: "bearer:newcomer", ip: newcomer_ip),
           "fail-closed must evict an under-limit identity, not refuse every newcomer (#498 H1)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end
end

class RateLimitIdentityFailClosedHttpTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper
  include RateLimitTestHelper

  setup do
    setup_smart_auth(scopes: "system/Patient.read system/*.read")
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "Patient search throttles a bearer spread across fresh IPs after the table fills with light IP buckets" do
    mod = rate_limit_module!
    max_requests = 3
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: 20)

    20.times do |i|
      mod.permit?(identity: nil, ip: "198.51.100.#{i + 1}")
    end

    spec = sample_request_for_route_key("lakeraven/ehr/patients#index")
    headers = { "Authorization" => "Bearer fail-closed-http-probe" }
    statuses = 30.times.map do |i|
      issue_integration_request!(
        verb: spec[:verb],
        path: spec[:path],
        params: spec[:params],
        headers: headers,
        env: integration_request_env(remote_addr: "203.0.113.#{i + 1}")
      )
      response.status
    end

    allowed = statuses.count { |status| status != 429 }
    assert_operator allowed, :<=, max_requests,
                     "HTTP layer must grant at most #{max_requests} non-429 responses (#498 H1); allowed=#{allowed}"
    throttled = statuses.count(429)
    assert_equal statuses.size - allowed, throttled,
                 "every throttled probe must return 429 (#498 H1); statuses=#{statuses.inspect}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end
end
