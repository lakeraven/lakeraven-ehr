# frozen_string_literal: true

module Lakeraven
  module EHR
    # A resource's week as a calendar (rpms-ux S-SCH-05): its days, each a
    # ClinicDay, laid on one time grid so a table can show time down and days
    # across. Built from one read of the week (AppointmentBookingGateway.days).
    class ClinicWeek
      # One cell: what a day holds at one step of the grid.
      # open: places left (nil outside the day's open blocks);
      # appointments: those starting within the step.
      Cell = Data.define(:date, :at, :open, :appointments) do
        def in_hours? = !open.nil?
        def full? = open&.zero?
      end

      # The grid a day with no hours and no bookings falls back to.
      DEFAULT_HOURS = (8...17)

      attr_reader :monday, :days, :time_scale

      # days: { Date => ClinicDay } for monday..monday + 6.
      def initialize(monday:, days:, time_scale:)
        @monday = monday
        @days = days
        @time_scale = [ time_scale.to_i, 1 ].max
      end

      def self.monday_of(date) = date - (date.cwday - 1)

      def sunday = monday + 6

      # Monday to Friday, and the weekend days that have hours or bookings.
      def dates
        (monday..sunday).select { |date| date.cwday <= 5 || busy?(date) }
      end

      # The grid's times of day, from the week's first open time or booking to
      # its last, on the resource's time scale: [hour, minute] pairs.
      def steps
        first, last = span
        (first...last).step(time_scale).map { |minutes| minutes.divmod(60) }
      end

      def cell(date, step)
        day = days.fetch(date)
        at = Time.new(date.year, date.month, date.day, *step)
        upto = at + (time_scale * 60)
        open = open_on(date)[at]
        starting = day.appointments.select { |a| a[:start_time] >= at && a[:start_time] < upto }.sort_by { |a| a[:start_time] }
        Cell.new(date: date, at: at, open: open, appointments: starting)
      end

      def closed(date) = days.fetch(date).closed

      private

      # A day's places left by time, read once per day.
      def open_on(date) = (@open_on ||= {})[date] ||= days.fetch(date).times.to_h { |t| [ t.at, t.open ] }

      def busy?(date)
        day = days.fetch(date)
        day.times.any? || day.appointments.any?
      end

      # Minutes after midnight the grid runs between.
      def span
        marks = days.values.flat_map do |day|
          day.blocks.flat_map { |b| [ minutes(b[:start_time]), minutes(b[:end_time]) ] } +
            day.appointments.flat_map { |a| [ minutes(a[:start_time]), minutes(a[:end_time] || a[:start_time]) ] }
        end
        return [ DEFAULT_HOURS.first * 60, DEFAULT_HOURS.last * 60 ] if marks.empty?

        first = marks.min - (marks.min % time_scale)
        [ first, [ marks.max, first + time_scale ].max ]
      end

      def minutes(time) = (time.hour * 60) + time.min
    end
  end
end
