# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # BSDX times carry no zone: rpms-rpc reads them as the server's local wall
    # clock (Time.new). What the scheduler enters must be read the same way, or a
    # booking is compared against the clinic's blocks hours apart on any host
    # that does not run in UTC.
    class WallClockTest < ActiveSupport::TestCase
      def in_zone(zone)
        before = ENV["TZ"]
        ENV["TZ"] = zone
        yield
      ensure
        ENV["TZ"] = before
      end

      test "an entered time is the same wall clock as the gem's block times" do
        in_zone("America/Los_Angeles") do
          assert_equal Time.new(2026, 11, 6, 11, 0, 0), WallClock.parse("2026-11-06T11:00")
        end
      end

      test "anything but a date and time is not a time" do
        assert_nil WallClock.parse("2026-11-06")
        assert_nil WallClock.parse("2026-13-40T11:00")
      end

      test "S-SCH-01.1 an open time on the clinic's day has room, on a host west of UTC" do
        in_zone("America/Los_Angeles") do
          day = Date.new(2026, 11, 6)
          block = { start_time: Time.new(day.year, day.month, day.day, 8), end_time: Time.new(day.year, day.month, day.day, 17), slots: 4 }
          booking = AppointmentBooking.new(start: "2026-11-06T11:00", length: 15)
          assert ClinicDay.new(blocks: [ block ], appointments: [], time_scale: 15).room_for?(booking.start_time, booking.length)
        end
      end

      test "S-SCH-03 a check-in later today is in the future, on a host west of UTC" do
        in_zone("America/Los_Angeles") do
          later = Time.now + 3600
          checkin = AppointmentCheckin.new(at: later.strftime("%Y-%m-%dT%H:%M"), appointment: { start_time: later })
          assert_not checkin.valid?
          assert_includes checkin.errors[:at], "cannot be in the future"
        end
      end
    end
  end
end
