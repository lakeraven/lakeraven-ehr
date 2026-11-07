# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduling supervisor enters to set a clinic's hours (rpms-ux
    # S-SCH-14): the weekdays, a start and end time, the appointments each slot
    # takes, an access type, and the first and last date. These checks name a
    # bad value before RPMS is asked (S-SCH-14.3); whether a day's bookings
    # still fit is ClinicHoursGateway's.
    class ClinicHours
      include ActiveModel::Model
      include ActiveModel::Attributes

      # Monday is 1 and Sunday 7, as Date#cwday counts them.
      WEEKDAYS = { 1 => "Monday", 2 => "Tuesday", 3 => "Wednesday", 4 => "Thursday", 5 => "Friday",
                   6 => "Saturday", 7 => "Sunday" }.freeze
      # A year at a time, so one save files a bounded number of blocks.
      MAX_DAYS = 366

      attribute :weekdays, default: -> { [] }
      attribute :opens, :string
      attribute :closes, :string
      attribute :slots, :integer
      attribute :access_type_id, :integer
      attribute :first_date, :string
      attribute :last_date, :string

      validates :slots, presence: true, numericality: { greater_than_or_equal_to: 1, allow_nil: true }
      validates :access_type_id, presence: { message: "is required: choose an access type" }
      validate :weekdays_chosen, :times_given, :dates_given

      def initialize(attrs = {})
        super
        self.weekdays = Array(weekdays).map(&:to_i).select { |d| WEEKDAYS.key?(d) }.uniq.sort
      end

      def first = parse_date(first_date)

      def last = parse_date(last_date)

      # The days in the range on a chosen weekday, the days whose blocks are set.
      def days = (first..last).select { |date| weekdays.include?(date.cwday) }

      # The block's start and end on a day, as the resource's wall-clock time.
      def opens_on(date) = at(date, opens)

      def closes_on(date) = at(date, closes)

      private

      def weekdays_chosen
        errors.add(:weekdays, "are required: choose at least one day") if weekdays.empty?
      end

      def times_given
        open_minutes = minutes(opens)
        close_minutes = minutes(closes)
        errors.add(:opens, "is not a time") if open_minutes.nil?
        errors.add(:closes, "is not a time") if close_minutes.nil?
        return if open_minutes.nil? || close_minutes.nil? || close_minutes > open_minutes

        errors.add(:closes, "must be after the start time")
      end

      def dates_given
        errors.add(:first_date, "is not a date") if first.nil?
        errors.add(:last_date, "is not a date") if last.nil?
        return if first.nil? || last.nil?

        errors.add(:last_date, "cannot be before the first date") if last < first
        errors.add(:last_date, "must be within #{MAX_DAYS} days of the first date") if (last - first).to_i >= MAX_DAYS
      end

      def parse_date(value)
        Date.iso8601(value.to_s)
      rescue Date::Error
        nil
      end

      # "HH:MM" as minutes after midnight, or nil.
      def minutes(value)
        match = value.to_s.match(/\A([01]\d|2[0-3]):([0-5]\d)\z/)
        match && (match[1].to_i * 60) + match[2].to_i
      end

      def at(date, value) = WallClock.parse("#{date.iso8601}T#{value}")
    end
  end
end
