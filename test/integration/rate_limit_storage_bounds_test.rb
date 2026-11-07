# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498 round-3: identity counter buckets must count toward max_keys.
class RateLimitStorageBoundsTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "distinct bearer identities from one IP count toward max_keys" do
    mod = rate_limit_module!
    assert_rate_limit_storage_countable!(mod)
    max_keys = 50
    mod.configure_for_test!(max_requests: 300, window: 10.minutes, max_keys: max_keys)

    100.times do |i|
      assert mod.permit?(identity: "bearer:one-ip-#{i}", ip: "198.51.100.88"),
             "grant #{i} must succeed under a generous per-identity limit (#498)"
    end

    stored = rate_limit_stored_bucket_count(mod)
    assert_operator stored, :<=, max_keys,
                    "identity buckets must count toward max_keys (#498); " \
                    "stored #{stored}, max_keys #{max_keys}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "flooding distinct bearers across many IPs cannot grow stored buckets past max_keys" do
    mod = rate_limit_module!
    assert_rate_limit_storage_countable!(mod)
    max_keys = 50
    mod.configure_for_test!(max_requests: 300, window: 10.minutes, max_keys: max_keys)

    1_000.times do |i|
      ip = "203.0.113.#{i % 250}"
      mod.permit?(identity: "bearer:flood-#{i}", ip: ip)
    end

    stored = rate_limit_stored_bucket_count(mod)
    assert_operator stored, :<=, max_keys,
                    "stored bucket count must stay within max_keys (#498); " \
                    "stored #{stored}, max_keys #{max_keys}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end
end
