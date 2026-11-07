# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler enters to check a patient in (rpms-ux S-SCH-03): the
    # time, the visit provider where the clinic requires one, and the clinic stop
    # (CLINIC STOP #40.7) where the clinic uses several.
    class AppointmentCheckin
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :at, :string
      attribute :provider_ien, :integer
      attribute :stop_id, :integer

      attr_accessor :appointment, :provider_required, :stop_required

      validates :at, presence: true
      validates :provider_ien, presence: { message: "is required at this clinic" }, if: -> { provider_required }
      validates :stop_id, presence: { message: "is required: this clinic uses several stops" }, if: -> { stop_required }
      validate :on_the_appointment_day_and_not_ahead

      # The check-in as the clinic's wall-clock time (WallClock).
      def time = WallClock.parse(at)

      private

      def on_the_appointment_day_and_not_ahead
        return if at.blank?
        return errors.add(:at, "is not a time") unless time

        errors.add(:at, "must be on the appointment's day") if appointment && time.to_date != appointment[:start_time].to_date
        errors.add(:at, "cannot be in the future") if time > Time.now
      end
    end
  end
end
