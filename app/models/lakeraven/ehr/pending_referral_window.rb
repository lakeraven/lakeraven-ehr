# frozen_string_literal: true

module Lakeraven
  module EHR
    # Which pending referrals the referral list and the dashboard count read
    # (#873): those whose DATE INITIATED falls in a range of dates, both ends
    # included. Unless the user chooses other dates, the last 12 months up to
    # today, so the list and the dashboard's count are the same referrals.
    module PendingReferralWindow
      MONTHS = 12

      def self.default(today = Date.today) = (today << MONTHS)..today

      # [window, error] from the list's from and to parameters; see DateWindow.
      def self.parse(from, to, today: Date.today)
        DateWindow.parse(from, to, default: default(today), today: today)
      end
    end
  end
end
