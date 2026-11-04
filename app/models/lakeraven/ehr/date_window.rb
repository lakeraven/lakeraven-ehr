# frozen_string_literal: true

module Lakeraven
  module EHR
    # A range of dates, both ends included, chosen on a list page by its from
    # and to parameters (YYYY-MM-DD). Each list names its own default and any
    # cap: PendingReferralWindow, NeedingActionWindow.
    module DateWindow
      # [window, error]. Both blank is the default window. Otherwise the error
      # names what is wrong and the window is nil, so nothing is read for dates
      # that were not what the user meant.
      def self.parse(from, to, default:, today:, max_days: nil)
        return [ default, nil ] if from.blank? && to.blank?

        first = iso_date(from)
        last = iso_date(to)
        return [ nil, "Enter both dates as year, month and day, for example #{today.iso8601}." ] unless first && last
        return [ nil, "The from date must be on or before the to date." ] if first > last
        return [ nil, "Choose at most #{max_days} days." ] if max_days && (last - first).to_i >= max_days

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
