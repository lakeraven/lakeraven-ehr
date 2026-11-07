# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#682: a global identity eviction floor must not ratchet under one-shot junk
# traffic and deny fresh legitimate bearers; newcomers should inherit only their victim's stamps.
class RateLimitFloorRatchetTest < ActiveSupport::TestCase
  include RateLimitTestHelper
  include ActiveSupport::Testing::TimeHelpers

  WINDOW = 60.seconds
  LIMIT = 300
  JUNK_PER_SECOND = 200
  LEGITIMATE_PROBE_HITS = 20
  MIN_LEGITIMATE_GRANTS = 18
  FLOOD_SECONDS = 120
  PROBE_SECONDS = [ 90, 100, 115 ].freeze

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "sustained one-shot junk flood at max_keys 2000 leaves legitimate bearers usable after t=90s (#682)" do
    mod = rate_limit_module!
    stats = assert_legitimate_bearer_under_junk_flood!(mod, max_keys: 2000)
    assert_operator stats[:junk_grants], :>, stats[:max_keys],
                    "junk flood must drive repeated evictions (#682); junk_grants=#{stats[:junk_grants]}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "sustained one-shot junk flood at max_keys 10000 leaves legitimate bearers usable after t=90s (#682)" do
    mod = rate_limit_module!
    stats = assert_legitimate_bearer_under_junk_flood!(mod, max_keys: 10_000)
    assert_operator stats[:junk_grants], :>, stats[:max_keys],
                    "junk flood must drive repeated evictions (#682); junk_grants=#{stats[:junk_grants]}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "a light identity evicted under junk pressure does not restart at zero (#682 regression)" do
    mod = rate_limit_module!
    max_keys = 8
    max_requests = 5
    mod.configure_for_test!(max_requests: max_requests, window: 10.minutes, max_keys: max_keys)
    max_keys.times { |i| mod.permit?(identity: nil, ip: "198.18.#{i / 250}.#{i % 250}") }

    granted = 0
    ipn = 0
    junk = 0
    20.times do
      (max_requests - 1).times do
        ipn += 1
        granted += 1 if mod.permit?(identity: "bearer:tracked", ip: "203.0.#{ipn / 250}.#{ipn % 250}")
      end
      junk += 1
      mod.permit?(identity: "bearer:junk#{junk}", ip: "192.0.#{junk / 250}.#{junk % 250}")
    end

    assert_operator granted, :>=, 1,
                    "tracked bearer must not be locked out from the start (#682 regression)"
    assert_operator granted, :<=, max_requests,
                    "evicting a tracked bearer must not reopen its counter (#682 regression); grants=#{granted}"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "an identity that cannot be stored is refused and changes nothing (#682 regression)" do
    mod = rate_limit_module!
    newcomer_ip = build_fail_closed_saturated_table!(mod)

    before_buckets = mod.bucket_count
    before_keys = mod.key_count
    refute mod.permit?(identity: "bearer:floor-ratchet-newcomer", ip: newcomer_ip),
           "new identity must be refused when it cannot be stored (#682 regression)"
    assert_equal before_buckets, mod.bucket_count,
                 "refusal must not mint buckets (#682 regression)"
    assert_equal before_keys, mod.key_count,
                 "refusal must not change key_count (#682 regression)"
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "after junk flood stops the identity floor drains within one window (#682)" do
    mod = rate_limit_module!
    max_keys = 2000
    mod.configure_for_test!(max_requests: LIMIT, window: WINDOW, max_keys: max_keys)

    travel_to Time.zone.parse("2026-06-01 12:00:00") do
      stats = run_one_shot_junk_flood!(mod, max_keys: max_keys, seconds: FLOOD_SECONDS)
      assert_flood_pressure!(mod, max_keys: max_keys, stats: stats)

      travel WINDOW + 1.second
      mod.sweep_expired! if mod.respond_to?(:sweep_expired!)

      grants = 0
      LIMIT.times do
        grants += 1 if mod.permit?(identity: "bearer:post-drain", ip: "192.0.2.200")
      end
      assert_equal LIMIT, grants,
                   "fresh identity must receive the full limit after the floor drains (#682); grants=#{grants}"
      refute mod.permit?(identity: "bearer:post-drain", ip: "192.0.2.200"),
             "first request past the limit must refuse (#682)"
    end
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  test "one bearer hammering past the limit is refused during an active junk flood (#682)" do
    mod = rate_limit_module!
    max_keys = 2000
    mod.configure_for_test!(max_requests: LIMIT, window: WINDOW, max_keys: max_keys)
    abuser_ip = "192.0.2.88"
    hammer_attempts = LIMIT + 200
    abuser_results = nil

    travel_to Time.zone.parse("2026-06-01 14:00:00") do
      stats = run_one_shot_junk_flood!(mod, max_keys: max_keys, seconds: 95) do |sec|
        next unless sec == 94

        abuser_results = hammer_attempts.times.map do
          mod.permit?(identity: "bearer:repeat-abuser", ip: abuser_ip)
        end
      end
      25.times do |offset|
        JUNK_PER_SECOND.times do |n|
          seq = stats[:junk_attempts] + (offset * JUNK_PER_SECOND) + n + 1
          mod.permit?(identity: "bearer:junk-#{seq}", ip: junk_ip(seq))
        end
        travel 1.second
      end
      stats[:junk_attempts] += 25 * JUNK_PER_SECOND
      assert_flood_pressure!(mod, max_keys: max_keys, stats: stats)

      refute_nil abuser_results, "abuser hammer must run while junk flood pressure is active (#682)"
      grants = abuser_results.count(true)
      refusals = abuser_results.count(false)
      inheritance_slack = abuser_inheritance_slack(max_keys: max_keys)
      assert_operator grants, :<=, LIMIT,
                      "repeat abuser must never exceed #{LIMIT} grants in the window (#682); grants=#{grants}"
      assert_operator grants, :>=, LIMIT - inheritance_slack,
                      "repeat abuser must reach at least #{LIMIT - inheritance_slack} grants during junk pressure " \
                      "(#682); inherited floor slack=#{inheritance_slack}, grants=#{grants}, refusals=#{refusals}"
      assert_operator refusals, :>, 0,
                      "hammer past the limit must refuse once the bucket is full (#682); grants=#{grants}, " \
                      "refusals=#{refusals}"
    end
  ensure
    mod.reset! if mod.respond_to?(:reset!)
  end

  private

  def assert_legitimate_bearer_under_junk_flood!(mod, max_keys:)
    mod.configure_for_test!(max_requests: LIMIT, window: WINDOW, max_keys: max_keys)
    probe_results = {}
    stats = nil

    travel_to Time.zone.parse("2026-06-01 10:00:00") do
      stats = run_one_shot_junk_flood!(mod, max_keys: max_keys, seconds: FLOOD_SECONDS) do |sec|
        next unless PROBE_SECONDS.include?(sec)

        probe_id = sec
        grants = legitimate_probe_grants(mod, probe_id)
        probe_results[sec] = grants
        assert_operator grants, :>=, MIN_LEGITIMATE_GRANTS,
                        "at t=#{sec}s a fresh legitimate bearer must grant at least #{MIN_LEGITIMATE_GRANTS} of " \
                        "#{LEGITIMATE_PROBE_HITS} requests (#682); grants=#{grants}, max_keys=#{max_keys}"
        assert_operator LEGITIMATE_PROBE_HITS - grants, :<=, LEGITIMATE_PROBE_HITS - MIN_LEGITIMATE_GRANTS,
                        "legitimate bearer must not lose more than #{LEGITIMATE_PROBE_HITS - MIN_LEGITIMATE_GRANTS} " \
                        "grants to floor ratchet (#682); grants=#{grants}"
      end
      assert_flood_pressure!(mod, max_keys: max_keys, stats: stats)
      PROBE_SECONDS.each do |sec|
        assert probe_results.key?(sec), "missing legitimate probe at t=#{sec}s (#682)"
      end
    end

    stats.merge(probe_results: probe_results)
  end

  def legitimate_probe_grants(mod, probe_id)
    identity = "bearer:legitimate-#{probe_id}"
    ip = "203.0.113.#{probe_id}"
    grants = 0
    LEGITIMATE_PROBE_HITS.times do
      grants += 1 if mod.permit?(identity: identity, ip: ip)
    end
    grants
  end

  def run_one_shot_junk_flood!(mod, max_keys:, seconds:, &each_second)
    junk_grants = 0
    junk_attempts = 0
    seconds.times do |sec|
      JUNK_PER_SECOND.times do
        junk_attempts += 1
        junk_grants += 1 if mod.permit?(identity: "bearer:junk-#{junk_attempts}", ip: junk_ip(junk_attempts))
      end
      yield sec if block_given?
      travel 1.second unless sec + 1 == seconds
    end
    {
      max_keys: max_keys,
      junk_attempts: junk_attempts,
      junk_grants: junk_grants,
      bucket_count: mod.bucket_count
    }
  end

  def assert_flood_pressure!(mod, max_keys:, stats:)
    assert_equal max_keys, mod.bucket_count,
                 "table must stay at capacity under junk flood (#682); bucket_count=#{mod.bucket_count}, " \
                 "max_keys=#{max_keys}"
    assert_operator stats[:junk_grants], :>, max_keys,
                   "junk flood must grant one-shot identities and churn the table (#682); " \
                   "junk_grants=#{stats[:junk_grants]}"
  end

  # Each junk grant occupies identity and IP slots; sustained churn bounds inherited stamps under min-inherit.
  def abuser_inheritance_slack(max_keys:)
    (2 * JUNK_PER_SECOND * WINDOW.to_i) / max_keys
  end

  def junk_ip(seq)
    "198.51.100.#{seq % 250}.#{seq / 250}"
  end
end
