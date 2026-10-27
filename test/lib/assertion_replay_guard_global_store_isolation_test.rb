# frozen_string_literal: true

require "test_helper"

class AssertionReplayGuardGlobalStoreIsolationTest < ActiveSupport::TestCase
  setup do
    Lakeraven::EHR::AssertionReplayGuard.reset!
  end

  teardown do
    Lakeraven::EHR::AssertionReplayGuard.reset!
  end

  test "GlobalStoreIsolation.reset! clears AssertionReplayGuard replay state" do
    client_id = "synthetic-client-589"
    jti = "synthetic-jti-589-#{SecureRandom.hex(8)}"
    exp = 5.minutes.from_now.to_i
    guard = Lakeraven::EHR::AssertionReplayGuard

    refute guard.replayed?(client_id, jti, exp),
           "first use of a jti should be accepted"
    assert guard.replayed?(client_id, jti, exp),
           "second use of the same jti should be refused"

    GlobalStoreIsolation.reset!

    refute guard.replayed?(client_id, jti, exp),
           "GlobalStoreIsolation.reset! should clear AssertionReplayGuard so the same jti is accepted again"
  end
end
