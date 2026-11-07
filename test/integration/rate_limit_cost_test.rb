# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498 round-3: permit? must not scan every stored bucket on each call.
class RateLimitCostTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "N1 repeated permit? for a known identity and IP stays fast with thousands of live keys" do
    mod = rate_limit_module!
    mod.configure_for_test!(max_requests: 300, window: 10.minutes, max_keys: 10_000)

    5_000.times do |i|
      ip = "203.0.113.#{i % 256}.#{i / 256}"
      assert mod.permit?(identity: nil, ip: ip),
             "seed permit #{i} must succeed (#498 N1)"
    end
    assert mod.permit?(identity: "access:known", ip: "198.51.100.42"),
           "known identity and IP must be present before timing (#498 N1)"

    started = monotonic_seconds
    2_000.times do
      mod.permit?(identity: "access:known", ip: "198.51.100.42")
    end
    elapsed = monotonic_seconds - started

    assert_operator elapsed, :<, 0.5,
                    "permit? must not scan the whole table each call (#498 N1); " \
                    "2,000 checks took #{elapsed.round(3)}s"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "N1 new-IP permit? on a full hot table stays fast" do
    mod = rate_limit_module!
    mod.configure_for_test!(max_requests: 300, window: 10.minutes, max_keys: 10_000)

    10_000.times do |i|
      octet = i % 256
      third = (i / 256) % 256
      second = (i / 65_536) % 256
      ip = "10.#{second}.#{third}.#{octet}"
      assert mod.permit?(identity: nil, ip: ip),
             "seed IP #{i} must fit in the hot table (#498 N1)"
    end
    assert_equal 10_000, mod.key_count,
                 "hot table must be full before measuring new-IP cost (#498 N1)"

    started = monotonic_seconds
    200.times do |i|
      mod.permit?(identity: nil, ip: "198.51.100.#{i}")
    end
    elapsed = monotonic_seconds - started

    assert_operator elapsed, :<, 1.0,
                    "new-IP permit? on a full table must not scan every key (#498 N1); " \
                    "200 inserts took #{elapsed.round(3)}s"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end
end
