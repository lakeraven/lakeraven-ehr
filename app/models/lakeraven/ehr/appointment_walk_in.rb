# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a clerk enters to book and check in a patient who arrived without an
    # appointment (rpms-ux S-SCH-06): the patient, the check-in time, the visit
    # provider where the clinic requires one, and the clinic stop where the
    # clinic uses several (CLINIC SETUP PARAMETERS #9009017.2). All of it is
    # checked before anything is filed (S-SCH-06.3).
    class AppointmentWalkIn
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :patient_dfn, :integer
      attribute :at, :string
      attribute :provider_ien, :integer
      attribute :stop_ien, :integer

      attr_accessor :provider_required, :stop_required

      validates :patient_dfn, presence: { message: "is required: choose a patient" }
      validates :at, presence: { message: "is required" }
      validates :provider_ien, presence: { message: "is required at this clinic" }, if: -> { provider_required }
      validates :stop_ien, presence: { message: "is required: this clinic uses several" }, if: -> { stop_required }
      validate :today_and_not_ahead

      # The check-in as the clinic's wall-clock time (WallClock).
      def time = WallClock.parse(at)

      private

      def today_and_not_ahead
        return if at.blank?
        return errors.add(:at, "is not a time") unless time

        errors.add(:at, "must be today: a walk-in is for a patient at the window") unless time.to_date == Date.today
        errors.add(:at, "cannot be in the future") if time > Time.now
      end
    end
  end
end
