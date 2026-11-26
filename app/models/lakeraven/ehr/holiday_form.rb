# frozen_string_literal: true

module Lakeraven
  module EHR
    # A holiday as a scheduling supervisor adds it (rpms-ux S-SCH-19): a date
    # from today through a year ahead (the list's window) and a name of 1 to 30 characters. Filed in HOLIDAY
    # (#40.5) by RpmsRpc::SchedulingSetup.add_holiday, which refuses the same
    # names (no ^, no control character, not exactly @).
    class HolidayForm
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :date, :string
      attribute :name, :string

      validates :name, presence: true, length: { maximum: 30 }
      validate :name_text_allowed
      validate :date_is_a_future_calendar_date

      def self.human_attribute_name(attribute, options = {})
        { name: "Name", date: "Date" }.fetch(attribute.to_sym) { super }
      end

      def name = super.to_s.strip.upcase.presence

      # The date as a Date, or nil when it is not a calendar date in ISO form.
      def calendar_date
        text = date.to_s.strip
        Date.iso8601(text) if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      rescue Date::Error
        nil
      end

      private

      def name_text_allowed
        return if name.blank?

        errors.add(:name, "cannot contain ^ or a control character") if name.include?("^") || name.match?(/[[:cntrl:]]/)
        errors.add(:name, "cannot be only @") if name == "@"
      end

      def date_is_a_future_calendar_date
        day = calendar_date
        if day.nil?
          errors.add(:date, "must be a real date such as 2031-07-04")
        elsif day < SiteTime.today
          errors.add(:date, "cannot be before today")
        elsif day > SiteTime.today.next_year
          errors.add(:date, "cannot be more than a year ahead")
        end
      end
    end
  end
end
