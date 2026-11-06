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

      # [window, error] from the list's from and to parameters; see DateWindow.
      def self.parse(from, to, today: Date.today)
        DateWindow.parse(from, to, default: default(today), today: today, max_days: MAX_DAYS)
      end
    end
  end
end
