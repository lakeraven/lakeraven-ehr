# frozen_string_literal: true

require "test_helper"

# "Today" as RPMS counts it (#1065): FileMan's DT, read with ORWU DT "T",
# not the app server's clock. The live proof, against a real RPMS a day
# behind the app's clock, is LiveRegistrationAddressHistoryRaceTest.
class SiteDateTest < ActiveSupport::TestCase
  setup { Lakeraven::EHR::SiteDate.reader = nil }

  teardown do
    RpmsRpc.client.seed_scalar(:orwu_dt, "T", "")
    Lakeraven::EHR::SiteDate.reader = -> { Date.current }
  end

  test "today is the day ORWU DT gives, even when the app's clock is a day ahead" do
    # ORWU DT "T" answers with FileMan's date and time (DT^ORWU, %DT "TS").
    RpmsRpc.client.seed_scalar(:orwu_dt, "T", "3261112.2113")

    travel_to(Time.utc(2026, 11, 13, 5, 13)) do
      assert_equal Date.new(2026, 11, 12), Lakeraven::EHR::SiteDate.today
      assert_equal [ "T", "TS" ], RpmsRpc.client.received_calls.reverse.find { |c| c[:rpc] == "ORWU DT" }[:params].to_a
    end
  end

  test "when RPMS gives no date, the app's own date is used and the failure is logged" do
    logged = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)

    assert_equal Date.current, Lakeraven::EHR::SiteDate.today
    assert_match(/RPMS did not give its date/, logged.string)
  ensure
    Rails.logger = original
  end
end
