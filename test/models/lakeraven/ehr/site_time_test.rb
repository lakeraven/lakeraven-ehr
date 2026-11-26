# frozen_string_literal: true

require "test_helper"

# The site's clock (#1065, #1114): FileMan's NOW, read with ORWU DT, not the
# app server's clock. The live proof, against a real RPMS a day behind the
# app's clock, is LiveRegistrationAddressHistoryRaceTest.
class SiteTimeTest < ActiveSupport::TestCase
  setup do
    @tz = ENV["TZ"]
    ENV["TZ"] = "UTC"
    Lakeraven::EHR::SiteTime.reader = nil
  end

  teardown do
    Lakeraven::EHR::SiteTime.reader = -> { Time.now }
    ENV["TZ"] = @tz
  end

  # Sunday Nov 8, 2026, 20:10:30 Pacific (UTC-8) is Monday 04:10:30 UTC.
  def at_sunday_evening_pacific(&)
    # ORWU DT "NOW" answers with FileMan's date and time (DT^ORWU, %DT "TS").
    RpmsStandIn.answer(RpmsRpc::Orwu, :fileman_datetime, "NOW", with: "3261108.201030")
    travel_to(Time.utc(2026, 11, 9, 4, 10, 30), &)
  end

  test "now and today are the time ORWU DT gives, though the app's clock is already tomorrow" do
    at_sunday_evening_pacific do
      assert_equal Time.new(2026, 11, 8, 20, 10, 30), Lakeraven::EHR::SiteTime.now
      assert_equal Date.new(2026, 11, 8), Lakeraven::EHR::SiteTime.today
      # "TS" (seconds) is the flag rpms-rpc sends unless told otherwise, so the engine asks for "NOW" alone.
      assert_equal({ args: [ "NOW" ], kwargs: {} }, RpmsStandIn.calls(RpmsRpc::Orwu, :fileman_datetime).last)
    end
  end

  test "RPMS is asked once per request" do
    at_sunday_evening_pacific do
      before = RpmsStandIn.calls(RpmsRpc::Orwu, :fileman_datetime).length
      3.times { Lakeraven::EHR::SiteTime.now }
      Lakeraven::EHR::SiteTime.local(Time.current)
      assert_equal before + 1, RpmsStandIn.calls(RpmsRpc::Orwu, :fileman_datetime).length
    end
  end

  test "an instant the app stored in UTC is shown on the site's clock" do
    at_sunday_evening_pacific do
      assert_equal(-8 * 3600, Lakeraven::EHR::SiteTime.utc_offset)
      shown = Lakeraven::EHR::SiteTime.local(Time.utc(2026, 11, 9, 1, 5))
      assert_equal "2026-11-08 17:05", shown.strftime("%Y-%m-%d %H:%M")
    end
  end

  test "a site clock a few minutes adrift still gives the site's zone" do
    RpmsStandIn.answer(RpmsRpc::Orwu, :fileman_datetime, "NOW", with: "3261108.2017")
    travel_to(Time.utc(2026, 11, 9, 4, 10)) do
      assert_equal(-8 * 3600, Lakeraven::EHR::SiteTime.utc_offset)
    end
  end

  test "when RPMS gives no time, the app's own clock is used and the failure is logged" do
    logged = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)

    travel_to(Time.utc(2026, 11, 9, 4, 10)) do
      assert_equal Time.now, Lakeraven::EHR::SiteTime.now
      assert_equal Date.new(2026, 11, 9), Lakeraven::EHR::SiteTime.today
      assert_equal 0, Lakeraven::EHR::SiteTime.utc_offset
    end
    assert_match(/RPMS did not give its time/, logged.string)
  ensure
    Rails.logger = original
  end
end
