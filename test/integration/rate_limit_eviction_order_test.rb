# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498 round-3: eviction must drop the lightest live hot key, not the heaviest.
class RateLimitEvictionOrderTest < ActionDispatch::IntegrationTest
  include RateLimitTestHelper

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "eviction keeps the heavy live IP bucket and drops a lighter one" do
    mod = rate_limit_module!
    heavy_ip = "198.51.100.10"
    light_ip = "198.51.100.11"
    mod.configure_for_test!(max_requests: 10, window: 10.minutes, max_keys: 2)

    9.times do
      assert mod.permit?(identity: nil, ip: heavy_ip),
             "heavy IP must accumulate hits before eviction pressure (#498)"
    end
    assert mod.permit?(identity: nil, ip: light_ip)
    assert mod.permit?(identity: nil, ip: "198.51.100.12"),
           "adding a third hot key must evict the lighter bucket, not the heavy one (#498)"

    assert mod.permit?(identity: nil, ip: heavy_ip),
           "heavy IP must still be near its limit after a lighter key is evicted (#498)"
    refute mod.permit?(identity: nil, ip: heavy_ip),
           "evicting the heaviest live key would reset its counter and break the limit (#498)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end
end
