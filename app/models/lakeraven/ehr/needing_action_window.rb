# frozen_string_literal: true

module Lakeraven
  module EHR
    # Which days the list of appointments needing action reads (#875, rpms-ux
    # S-SCH-13.5): a range of dates, both ends included. Unless the scheduler
    # chooses other dates, today, so the list and the dashboard's count are the
    # same appointments. A range is at most MAX_DAYS long: each clinic's days
    # are read in one call, and a longer range is a report for RPMS's own
    # Appointments Requiring Action (BSDAMR2).
    module NeedingActionWindow
      MAX_DAYS = 31

      def self.default(today = Date.today) = today..today

      # [window, error] from the list's from and to parameters (YYYY-MM-DD).
      # Both blank is the default window. Otherwise the error names what is
      # wrong and the window is nil, so nothing is read for dates that were
      # not what the user meant.
      def self.parse(from, to, today: Date.today)
        return [ default(today), nil ] if from.blank? && to.blank?

        first = iso_date(from)
        last = iso_date(to)
        return [ nil, "Enter both dates as year, month and day, for example #{today.iso8601}." ] unless first && last
        return [ nil, "The from date must be on or before the to date." ] if first > last
        return [ nil, "Choose at most #{MAX_DAYS} days." ] if (last - first).to_i >= MAX_DAYS

        [ first..last, nil ]
      end

      def self.iso_date(value)
        Date.iso8601(value.to_s)
      rescue Date::Error
        nil
      end
      private_class_method :iso_date
    end
  end
end
