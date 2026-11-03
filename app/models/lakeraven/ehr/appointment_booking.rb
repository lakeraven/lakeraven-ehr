# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler enters to book an appointment (rpms-ux S-SCH-01). These
    # checks name what is missing or malformed before RPMS is asked; whether
    # the time has room is ClinicDay's, and the rest is the server's.
    class AppointmentBooking
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :patient_dfn, :integer
      attribute :start, :string
      attribute :length, :integer
      attribute :note, :string

      validates :patient_dfn, presence: { message: "is required: choose a patient" }
      validates :start, presence: true
      validates :length, presence: true, numericality: { greater_than: 0, allow_nil: true }
      # The scheduling client's rule for an appointment note: 2 to 150
      # characters, no semicolon or colon (they delimit the note on the wire).
      validates :note, length: { in: 2..150 }, allow_blank: true
      validates :note, format: { without: /[;:]/, message: "cannot contain a semicolon or a colon" }, allow_blank: true
      validate :start_is_a_time

      def initialize(attrs = {})
        super
        self.note = note.to_s.strip.presence
      end

      # The start as the resource's wall-clock time (WallClock).
      def start_time = WallClock.parse(start)

      def end_time = start_time && start_time + (length.to_i * 60)

      private

      def start_is_a_time
        errors.add(:start, "is not a time") if start.present? && start_time.nil?
      end
    end
  end
end
