# frozen_string_literal: true

module Lakeraven
  module EHR
    # When the patient left (rpms-ux S-SCH-07): a time on or after the
    # appointment's day, at least a minute after the check-in, and not more
    # than five minutes ahead of now (S-SCH-07.3, 07.4). BSDX CHECKOUT
    # APPOINTMENT refuses any time ahead of the server's clock, so a time a
    # few minutes ahead is filed as now.
    class AppointmentCheckout
      include ActiveModel::Model
      include ActiveModel::Attributes

      LEEWAY = 5 * 60

      attribute :at, :string

      attr_accessor :appointment

      validates :at, presence: true
      validate :after_the_checkin_and_not_ahead

      # The check-out as the clinic's wall-clock time (WallClock), brought back
      # to now when it is a few minutes ahead.
      def time
        entered = WallClock.parse(at)
        entered && [ entered, Time.now ].min
      end

      private

      def after_the_checkin_and_not_ahead
        return if at.blank?

        entered = WallClock.parse(at)
        return errors.add(:at, "is not a time") unless entered
        return errors.add(:at, "cannot be more than 5 minutes from now") if entered > Time.now + LEEWAY

        errors.add(:at, "cannot be before the appointment's day") if appointment && entered.to_date < appointment[:start_time].to_date
        checked_in = appointment&.dig(:checkin_time)
        errors.add(:at, "must be at least a minute after the check-in at #{checked_in.strftime('%H:%M')}") if checked_in && entered < checked_in + 60
      end
    end
  end
end
