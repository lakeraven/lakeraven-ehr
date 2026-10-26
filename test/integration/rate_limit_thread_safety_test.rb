# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#498: concurrent permit? calls must not grant more than max_requests.
class RateLimitThreadSafetyTest < ActiveSupport::TestCase
  include RateLimitTestHelper

  teardown do
    Lakeraven::EHR::RateLimit.reset! if Lakeraven::EHR.const_defined?(:RateLimit, false) &&
      Lakeraven::EHR::RateLimit.respond_to?(:reset!)
  end

  test "concurrent permit? grants exactly max_requests for one identity and IP" do
    mod = rate_limit_module!
    # Opus reproduced large over-grants at this scale without synchronization (#498).
    max = 1500
    identity = "bearer:thread-safety"
    ip = "198.51.100.77"
    threads = 5
    calls_per_thread = 1000
    iterations = 3

    iterations.times do |run|
      mod.configure_for_test!(max_requests: max, window: 1.minute)
      granted = 0
      grant_lock = Mutex.new

      workers = Array.new(threads) do
        Thread.new do
          calls_per_thread.times do
            next unless mod.permit?(identity: identity, ip: ip)

            grant_lock.synchronize { granted += 1 }
          end
        end
      end
      workers.each(&:join)

      assert_equal max, granted,
                   "iteration #{run + 1}: concurrent permit? must grant exactly max_requests (#498); " \
                   "saw #{granted} grants with #{threads}×#{calls_per_thread} calls"
      mod.reset!
    end
  end
end
