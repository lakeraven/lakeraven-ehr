# frozen_string_literal: true

module Lakeraven
  module EHR
    # One resource's day for booking (rpms-ux S-SCH-01): its access blocks and
    # the appointments already on it, on the resource's slot grid.
    #
    # A block's slots is how many appointments it holds at a time. BSDX ADD NEW
    # APPOINTMENT does not enforce it (a fifth booking into a four-slot block
    # files), so this is where a booking is checked against it, the way the
    # scheduling client checks. A time outside every open block has no room.
    class ClinicDay
      Time_ = Data.define(:at, :open)

      attr_reader :blocks, :appointments, :time_scale, :closed, :opens_hour

      # blocks: Scheduling.slot_schedule rows; appointments: rows with
      # :start_time/:end_time on this resource; time_scale: minutes. closed: why
      # the day takes no booking (closed_on), or nil; a closed day has no open
      # block. prevented: the ids of access types that prevent access, whose
      # blocks take no booking (S-SCH-04.2). opens_hour: the clinic's display
      # start hour, before which the search offers no time (S-SCH-04.1).
      def initialize(blocks:, appointments:, time_scale:, closed: nil, prevented: [], opens_hour: nil)
        @closed = closed
        @blocks = closed ? [] : Array(blocks).select { |b| b[:slots].to_i.positive? && !prevented.include?(b[:access_type_id]) }
        @appointments = Array(appointments)
        @time_scale = [ time_scale.to_i, 1 ].max
        @opens_hour = opens_hour
      end

      # Why date takes no booking at all at a clinic (S-SCH-04.3, 04.4), under
      # its rules (SchedulingSetup.clinic_rules; nil for none) and the dates of
      # the holidays, as of today: :holiday when the clinic does not schedule on
      # holidays, :beyond_booking past its maximum days for future booking,
      # :inactive from its inactivate date until a later reactivate date; else nil.
      def self.closed_on(date, rules:, holidays:, today:)
        return nil unless rules
        return :holiday if holidays.include?(date) && !rules[:schedule_on_holidays]
        return :beyond_booking if rules[:max_future_days] && date > today + rules[:max_future_days]

        off = rules[:inactivate_date]
        back = rules[:reactivate_date]
        :inactive if off && date >= off && (back.nil? || back <= off || date < back)
      end

      # Every time on the grid within an open block, with the places left.
      def times
        blocks.flat_map do |block|
          steps(block[:start_time], block[:end_time]).map { |at| Time_.new(at: at, open: open_at(block, at)) }
        end
      end

      # Whether an appointment from start for length minutes fits: one open block
      # holds all of it, and every step of it has a place left.
      # access_type keeps it to blocks of that type (S-SCH-04.6).
      def room_for?(start, length, access_type: nil)
        finish = start + (length.to_i * 60)
        block = blocks.find { |b| (access_type.nil? || b[:access_type_id] == access_type) && b[:start_time] <= start && finish <= b[:end_time] }
        return false unless block && length.to_i.positive?

        steps(start, finish).all? { |at| open_at(block, at).positive? }
      end

      # The times an appointment of length minutes fits (room_for?), on the grid,
      # from the clinic's display start hour, optionally only before noon ("am")
      # or from noon ("pm"), and only in blocks of one access type: S-SCH-04.
      def open_times(length, part: nil, access_type: nil)
        times.map(&:at).uniq.select do |at|
          (opens_hour.nil? || at.hour >= opens_hour) && in_part?(at, part) && room_for?(at, length, access_type: access_type)
        end
      end

      private

      def in_part?(at, part)
        case part.to_s
        when "am" then at.hour < 12
        when "pm" then at.hour >= 12
        else true
        end
      end

      def steps(from, to)
        out = []
        at = from
        while at < to
          out << at
          at += time_scale * 60
        end
        out
      end

      def open_at(block, at)
        upto = at + (time_scale * 60)
        booked = appointments.count { |a| a[:start_time] < upto && a[:end_time] > at }
        [ block[:slots].to_i - booked, 0 ].max
      end
    end
  end
end
