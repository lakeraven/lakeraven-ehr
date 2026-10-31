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

      # S-SCH-04.1: an open time starts in an open block, the appointment ends
      # within it, and every step of it has a place left.
      test "S-SCH-04.1 the open times for a length are the times an appointment of it fits" do
        full = day(Array.new(4) { appt(10, 0, 30) })
        open = full.open_times(30)

        assert_equal at(8), open.first
        assert_equal at(16, 30), open.last, "16:45 would run past the 17:00 end of the block"
        refute_includes open, at(10)
        refute_includes open, at(9, 45), "09:45 for 30 minutes would reach the full 10:00 step"
        assert_includes open, at(10, 30)
      end

      test "S-SCH-04.5 the open times can be kept to the morning or the afternoon" do
        assert(day.open_times(15, part: "am").all? { |t| t.hour < 12 })
        assert_equal at(12), day.open_times(15, part: "pm").first
        assert_equal day.open_times(15), day.open_times(15, part: "am") + day.open_times(15, part: "pm")
      end

      # SchedulingSetup.clinic_rules' shape, as a live 7c3119b build answered it.
      def rules(**over)
        { id: 3, display_begins: 8, schedule_on_holidays: true, max_future_days: 90, prohibit_access: false,
          inactivate_date: nil, reactivate_date: nil }.merge(over)
      end

      def closed_on(date, holidays: [], **over) = ClinicDay.closed_on(date, rules: rules(**over), holidays: holidays, today: DAY)

      test "a clinic with no rules, or none that apply, is open" do
        assert_nil ClinicDay.closed_on(DAY, rules: nil, holidays: [ DAY ], today: DAY)
        assert_nil closed_on(DAY, holidays: [ DAY ])
      end

      test "the last day inside the booking limit is open and the day after is not" do
        assert_nil closed_on(DAY + 90)
        assert_equal :beyond_booking, closed_on(DAY + 91)
      end

      test "a clinic is inactive from its inactivate date until a later reactivate date" do
        assert_nil closed_on(DAY - 1, inactivate_date: DAY, reactivate_date: DAY + 2)
        assert_equal :inactive, closed_on(DAY + 1, inactivate_date: DAY, reactivate_date: DAY + 2)
        assert_nil closed_on(DAY + 2, inactivate_date: DAY, reactivate_date: DAY + 2)
        assert_equal :inactive, closed_on(DAY + 30, inactivate_date: DAY), "no reactivate date"
        assert_equal :inactive, closed_on(DAY + 30, inactivate_date: DAY, reactivate_date: DAY - 5), "reactivated before it was inactivated again"
      end

      test "a closed day has no open block, and a block whose type prevents access takes no booking" do
        typed = blocks.map { |b| b.merge(access_type_id: 1) } + [ { start_time: at(17), end_time: at(18), slots: 2, access_type_id: 2 } ]

        assert_empty ClinicDay.new(blocks: typed, appointments: [], time_scale: 15, closed: :holiday).times
        refute ClinicDay.new(blocks: typed, appointments: [], time_scale: 15, prevented: [ 2 ]).room_for?(at(17), 15)
        assert ClinicDay.new(blocks: typed, appointments: [], time_scale: 15).room_for?(at(17), 15, access_type: 2)
      end
    end
  end
end
