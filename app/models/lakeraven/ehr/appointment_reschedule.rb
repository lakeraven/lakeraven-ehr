# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler enters to move an appointment (rpms-ux S-SCH-02.8): the
    # clinic and time it moves to, who asked for the move, and the cancellation
    # reason the original is filed with. The original's remark says where it
    # went (#remark); the scheduler may add a few words to it.
    class AppointmentReschedule
      include ActiveModel::Model
      include ActiveModel::Attributes

      # CANCEL^BSDAPI files at most 160 characters of remarks (#2.98 field 17).
      REMARKS_MAX = 160

      attribute :resource_id, :integer
      attribute :start, :string
      attribute :whom, :string
      attribute :reason_ien, :integer
      attribute :extra, :string

      validates :resource_id, presence: { message: "is required: choose a clinic" }
      validates :start, presence: { message: "is required: choose a new time" }
      validates :whom, inclusion: { in: AppointmentCancellation::WHOM.keys, message: "must say whether the patient or the clinic asked" }
      validates :reason_ien, presence: { message: "is required" }
      # Remarks are filed into a FileMan DR string, where a semicolon ends the
      # value, and sent over the broker, where a caret splits it.
      validates :extra, format: { without: /[;^]/, message: "cannot contain a semicolon or a caret" }, allow_blank: true
      validate :start_is_a_time

      def initialize(attrs = {})
        super
        self.extra = extra.to_s.squish.presence
      end

      def start_time = WallClock.parse(start)

      # The cancellation remark the original is filed with: where it moved to,
      # then the scheduler's words, cut to what RPMS keeps.
      def remark(clinic_name)
        [ "Rescheduled to #{start_time.strftime('%b %-d, %Y %H%M')} #{clinic_name}", extra ].compact.join(". ")[0, REMARKS_MAX]
      end

      private

      def start_is_a_time
        errors.add(:start, "is not a time") if start.present? && start_time.nil?
      end
    end
  end
end
