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

      attr_reader :blocks, :appointments, :time_scale

      # blocks: Scheduling.slot_schedule rows; appointments: rows with
      # :start_time/:end_time on this resource; time_scale: minutes.
      def initialize(blocks:, appointments:, time_scale:)
        @blocks = Array(blocks).select { |b| b[:slots].to_i.positive? }
        @appointments = Array(appointments)
        @time_scale = [ time_scale.to_i, 1 ].max
      end

      # Every time on the grid within an open block, with the places left.
      def times
        blocks.flat_map do |block|
          steps(block[:start_time], block[:end_time]).map { |at| Time_.new(at: at, open: open_at(block, at)) }
        end
      end

      # Whether an appointment from start for length minutes fits: one open block
      # holds all of it, and every step of it has a place left.
      def room_for?(start, length)
        finish = start + (length.to_i * 60)
        block = blocks.find { |b| b[:start_time] <= start && finish <= b[:end_time] }
        return false unless block && length.to_i.positive?

        steps(start, finish).all? { |at| open_at(block, at).positive? }
      end

      private

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
