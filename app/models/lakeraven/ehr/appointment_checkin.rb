# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler enters to check a patient in (rpms-ux S-SCH-03): the
    # time, and the visit provider where the clinic requires one.
    class AppointmentCheckin
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :at, :string
      attribute :provider_ien, :integer

      attr_accessor :appointment, :provider_required

      validates :at, presence: true
      validates :provider_ien, presence: { message: "is required at this clinic" }, if: -> { provider_required }
      validate :on_the_appointment_day_and_not_ahead

      # The check-in as the clinic's wall-clock time (BSDX times carry no zone).
      def time
        m = at.to_s.match(/\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})\z/)
        m && Time.utc(*m.captures.map(&:to_i))
      rescue ArgumentError
        nil
      end

      private

      def on_the_appointment_day_and_not_ahead
        return if at.blank?
        return errors.add(:at, "is not a time") unless time

        errors.add(:at, "must be on the appointment's day") if appointment && time.to_date != appointment[:start_time].to_date
        errors.add(:at, "cannot be in the future") if time > Time.now.utc
      end
    end
  end
end
