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
