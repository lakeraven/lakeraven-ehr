# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AssertionReplayGuardTest < ActiveSupport::TestCase
      setup do
        AssertionReplayGuard.reset!
      end

      teardown do
        AssertionReplayGuard.reset!
      end

      test "first use of a jti is accepted, second is refused" do
        exp = 5.minutes.from_now.to_i
        refute AssertionReplayGuard.replayed?("client-1", "jti-1", exp)
        assert AssertionReplayGuard.replayed?("client-1", "jti-1", exp)
      end

      test "the same jti from a different client is independent" do
        exp = 5.minutes.from_now.to_i
        refute AssertionReplayGuard.replayed?("client-1", "jti-1", exp)
        refute AssertionReplayGuard.replayed?("client-2", "jti-1", exp)
      end

      test "a used jti is refused even after in-process state is lost (worker restart / sibling worker)" do
        exp = 5.minutes.from_now.to_i
        refute AssertionReplayGuard.replayed?("client-1", "jti-1", exp)

        # Simulate a Puma worker restart (or the request landing on a sibling
        # worker): any per-process memory is gone. The guard must be backed
        # by shared state, so the jti stays refused.
        AssertionReplayGuard.instance_variables.each do |ivar|
          value = AssertionReplayGuard.instance_variable_get(ivar)
          AssertionReplayGuard.instance_variable_set(ivar, {}) if value.is_a?(Hash)
        end

        assert AssertionReplayGuard.replayed?("client-1", "jti-1", exp),
          "jti must be refused from shared state, not per-process memory"
      end

      test "a jti whose assertion lifetime has passed no longer blocks" do
        refute AssertionReplayGuard.replayed?("client-1", "jti-1", 2.minutes.ago.to_i)
        refute AssertionReplayGuard.replayed?("client-1", "jti-1", 5.minutes.from_now.to_i)
      end

      test "concurrent first uses admit exactly one caller" do
        exp = 5.minutes.from_now.to_i
        results = 8.times.map do |i|
          Thread.new { AssertionReplayGuard.replayed?("client-1", "jti-race", exp) }
        end.map(&:value)

        assert_equal 1, results.count(false), "exactly one use may be accepted"
      end
    end
  end
end
