# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ClinicDayTest < ActiveSupport::TestCase
      DAY = Date.new(2026, 10, 28)

      def at(hour, min = 0) = Time.new(DAY.year, DAY.month, DAY.day, hour, min, 0)

      # The live shape: padding blocks with 0 slots around an 08:00-17:00 block of 4.
      def blocks
        [ { start_time: at(0, 1), end_time: at(8), slots: 0 },
          { start_time: at(8), end_time: at(17), slots: 4 },
          { start_time: at(17), end_time: at(23, 59), slots: 0 } ]
      end

      def appt(hour, min, length) = { start_time: at(hour, min), end_time: at(hour, min) + (length * 60) }

      def day(appointments = []) = ClinicDay.new(blocks: blocks, appointments: appointments, time_scale: 15)

      test "the grid covers only open blocks, at the resource's time scale" do
        times = day.times

        assert_equal at(8), times.first.at
        assert_equal at(16, 45), times.last.at
        assert_equal 36, times.size
        assert(times.all? { |t| t.open == 4 })
      end

      test "an appointment takes a place at every step it covers" do
        times = day([ appt(9, 0, 20) ]).times.to_h { |t| [ t.at, t.open ] }

        assert_equal 3, times[at(9)]
        assert_equal 3, times[at(9, 15)]
        assert_equal 4, times[at(9, 30)]
      end

      test "a time with all its places taken has no room, and the time after does" do
        full = day(Array.new(4) { appt(10, 0, 20) })

        refute full.room_for?(at(10), 20)
        refute full.room_for?(at(10, 15), 15), "10:15 is still covered by the 10:00-10:20 appointments"
        assert full.room_for?(at(10, 30), 15)
      end

      test "a booking that runs past its block, or outside every open block, has no room" do
        refute day.room_for?(at(16, 45), 30)
        refute day.room_for?(at(7, 30), 15)
        refute day.room_for?(at(17, 30), 15)
      end

      test "a booking with no length has no room" do
        refute day.room_for?(at(9), 0)
      end
    end
  end
end
