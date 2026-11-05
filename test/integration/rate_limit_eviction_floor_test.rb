# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498 review round 1: evicting a counter must not reset its holder;
# refused requests must not evict; fresh identities start at zero when nothing was evicted.
class RateLimitEvictionFloorTest < ActiveSupport::TestCase
  include RateLimitTestHelper

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "A1 evicting must not let bearer B restart after junk pressure at max_keys 8 max_requests 5" do
    mod = rate_limit_module!
    granted = bearer_b_eviction_repro_grants(mod, max_keys: 8, max_requests: 5)
    assert_operator granted, :>=, 1,
                    "bearer B must not be locked out from the start (#498 eviction floor)"
    assert_operator granted, :<=, 5,
                    "evicting bearer B must not reopen its counter (#498 eviction floor); grants=#{granted}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "A2 evicting must not let bearer B restart after junk pressure at max_keys 64 max_requests 10" do
    mod = rate_limit_module!
    granted = bearer_b_eviction_repro_grants(mod, max_keys: 64, max_requests: 10)
    assert_operator granted, :>=, 1,
                    "bearer B must not be locked out from the start (#498 eviction floor)"
    assert_operator granted, :<=, 10,
                    "evicting bearer B must not reopen its counter (#498 eviction floor); grants=#{granted}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "A3 evicting must not let a tracked IP restart after fresh-IP pressure" do
    mod = rate_limit_module!
    max_keys = 8
    max_requests = 5
    tracked_ip = "192.0.2.77"
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: max_keys)
    max_keys.times { |i| mod.permit?(identity: nil, ip: "198.18.#{i / 250}.#{i % 250}") }

    grants = 0
    fresh = 0
    20.times do
      (max_requests - 1).times do
        grants += 1 if mod.permit?(identity: nil, ip: tracked_ip)
      end
      fresh += 1
      mod.permit?(identity: nil, ip: "198.51.100.#{fresh}")
    end

    assert_operator grants, :<=, max_requests,
                    "evicting IP #{tracked_ip} must not reopen its counter (#498 eviction floor); grants=#{grants}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "A4 a fresh identity starts at zero when nothing has been evicted yet" do
    mod = rate_limit_module!
    mod.configure_for_test!(max_requests: 3, window: 10.minutes, max_keys: 50)
    3.times do
      assert mod.permit?(identity: "bearer:fresh", ip: "192.0.2.5"),
             "fresh identity must grant under the limit (#498 eviction floor)"
    end
    refute mod.permit?(identity: "bearer:fresh", ip: "192.0.2.5"),
           "fourth hit must refuse (#498 eviction floor)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "B1 a refused request evicts nothing when the table is full at max_keys 2" do
    mod = rate_limit_module!
    mod.configure_for_test!(max_requests: 1, window: 10.minutes, max_keys: 2)

    assert mod.permit?(identity: "bearer:one", ip: "198.51.100.60")
    assert_equal 2, mod.bucket_count

    keys_before = mod.key_count
    refute mod.permit?(identity: "bearer:three", ip: "198.51.100.61"),
           "new identity on a new IP must be refused when only one slot is evictable (#498 refusal evicts nothing)"

    assert_equal 2, mod.bucket_count,
                 "refusal must not shrink bucket_count (#498 refusal evicts nothing); saw #{mod.bucket_count}"
    assert_equal keys_before, mod.key_count,
                 "refusal must not change key_count (#498 refusal evicts nothing)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "B2 a refused request evicts nothing when only a light identity is evictable at max_keys 3" do
    mod = rate_limit_module!
    max_requests = 2
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: 3)

    assert mod.permit?(identity: "bearer:one", ip: "198.51.100.60"),
           "bearer:one must stay light on .60 (#498 refusal evicts nothing)"
    assert mod.permit?(identity: nil, ip: "198.51.100.60"),
           "second hit on .60 must saturate the IP with bearer:one still at 1 of 2 (#498)"
    refute mod.permit?(identity: nil, ip: "198.51.100.60"),
           ".60 must be saturated (#498 refusal evicts nothing)"
    max_requests.times do
      assert mod.permit?(identity: nil, ip: "198.51.100.63"),
             ".63 must admit under its limit (#498 refusal evicts nothing)"
    end
    refute mod.permit?(identity: nil, ip: "198.51.100.63"),
           ".63 must be saturated (#498 refusal evicts nothing)"
    assert_equal 3, mod.bucket_count

    keys_before = mod.key_count
    refute mod.permit?(identity: "bearer:newcomer", ip: "198.51.100.64"),
           "two new slots with only one evictable key must refuse (#498 refusal evicts nothing)"

    assert_equal 3, mod.bucket_count,
                 "refusal must not shrink bucket_count (#498 refusal evicts nothing); saw #{mod.bucket_count}"
    assert_equal keys_before, mod.key_count,
                 "refusal must not change key_count (#498 refusal evicts nothing)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  def bearer_b_eviction_repro_grants(mod, max_keys:, max_requests:)
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: max_keys)
    max_keys.times { |i| mod.permit?(identity: nil, ip: "198.18.#{i / 250}.#{i % 250}") }

    granted = 0
    ipn = 0
    junk = 0
    20.times do
      (max_requests - 1).times do
        ipn += 1
        granted += 1 if mod.permit?(identity: "bearer:B", ip: "203.0.#{ipn / 250}.#{ipn % 250}")
      end
      junk += 1
      mod.permit?(identity: "bearer:junk#{junk}", ip: "192.0.#{junk / 250}.#{junk % 250}")
    end
    granted
  end
end
