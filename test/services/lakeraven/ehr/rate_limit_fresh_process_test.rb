# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#1002: the rate limiter's sweep must never fail a request.
#
# A production process never calls reset!, configure_for_test! or
# clear_counters!, so the counter state starts out as unset instance
# variables (notably @cursor = nil). Every SWEEP_EVERY-th permit? sweeps, and
# the sweep must cope with that state instead of raising TypeError.
class RateLimitFreshProcessTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  LIMITER = Lakeraven::EHR::RateLimit

  # Everything clear_counters! / configure_for_test! / reset! assigns. @mutex,
  # @declared_keys and @observed_controllers are boot-time state and stay.
  COUNTER_IVARS = %i[
    @buckets @hot @retained @audited @order @key_index @seq @calls @cursor
    @floors @floor_caps @pending_inheritance @max_requests @window @max_keys
  ].freeze

  setup do
    simulate_fresh_process!
  end

  teardown do
    travel_back
    LIMITER.reset!
  end

  test "fresh-process helper leaves the limiter without a cursor and keeps the mutex" do
    assert_not LIMITER.instance_variable_defined?(:@cursor)
    assert_not LIMITER.instance_variable_defined?(:@calls)
    assert_kind_of Mutex, LIMITER.instance_variable_get(:@mutex)
  end

  test "distinct callers crossing several sweep boundaries are all granted without raising" do
    total = (3 * LIMITER::SWEEP_EVERY) + 1
    results = []

    assert_nothing_raised do
      total.times do |n|
        results << LIMITER.permit?(identity: "bearer:fresh-#{n}", ip: synthetic_ip(n))
      end
    end

    assert_equal total, results.size
    assert results.all? { |r| r == true || r == false }, "permit? must answer a boolean"
    assert results.all?, "default limits must grant every distinct caller; " \
                         "refused at calls #{results.each_index.reject { |i| results[i] }.map { |i| i + 1 }.inspect}"
  end

  test "the SWEEP_EVERY-th call of a never-reset limiter is granted, not a TypeError" do
    results = []

    assert_nothing_raised do
      LIMITER::SWEEP_EVERY.times do |n|
        results << LIMITER.permit?(identity: "bearer:fresh-boundary-#{n}", ip: synthetic_ip(n))
      end
    end

    assert_equal true, results.last
  end

  test "one caller past the sweep boundary is granted and the default limit still applies" do
    identity = "bearer:fresh-single"
    ip = "198.51.100.7"
    limit = LIMITER::DEFAULT_MAX_REQUESTS
    assert_operator limit, :>, LIMITER::SWEEP_EVERY + 1

    freeze_time do
      results = []
      assert_nothing_raised do
        (limit + 1).times { results << LIMITER.permit?(identity: identity, ip: ip) }
      end

      first = results.first(LIMITER::SWEEP_EVERY + 1)
      assert first.all?, "calls 1..#{LIMITER::SWEEP_EVERY + 1} must be granted"
      assert results.first(limit).all?, "calls 1..#{limit} must be granted under the default limit"
      assert_equal false, results.last, "call #{limit + 1} must be refused under the default limit"
      assert_equal limit, LIMITER.max_requests
    end
  end

  test "sweep_expired! on a never-reset limiter that holds buckets does not raise" do
    # Stay below SWEEP_EVERY so only the explicit sweep runs.
    10.times { |n| assert LIMITER.permit?(identity: "bearer:fresh-sweep-#{n}", ip: synthetic_ip(n)) }
    assert_operator LIMITER.bucket_count, :>, 0

    assert_nothing_raised { LIMITER.sweep_expired! }
    assert_operator LIMITER.bucket_count, :>, 0, "live buckets survive the sweep"

    travel LIMITER::DEFAULT_WINDOW + 1.second
    assert_nothing_raised { LIMITER.sweep_expired! }
    assert_equal 0, LIMITER.bucket_count, "expired buckets are swept"
  end

  private

  # The state of a process that loaded the class and never ran reset!,
  # configure_for_test! or clear_counters!.
  def simulate_fresh_process!
    LIMITER.send(:mutex).synchronize do
      COUNTER_IVARS.each do |ivar|
        LIMITER.remove_instance_variable(ivar) if LIMITER.instance_variable_defined?(ivar)
      end
    end
  end

  # Documentation ranges only (RFC 5737).
  def synthetic_ip(n)
    prefix = n.even? ? "198.51.100" : "203.0.113"
    "#{prefix}.#{(n % 250) + 1}"
  end
end
