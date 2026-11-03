# frozen_string_literal: true

module Lakeraven
  module EHR
    # What a scheduler enters to cancel an appointment (rpms-ux S-SCH-02).
    class AppointmentCancellation
      include ActiveModel::Model
      include ActiveModel::Attributes

      WHOM = { "C" => "the clinic", "PC" => "the patient" }.freeze

      attribute :whom, :string
      attribute :reason_ien, :integer
      attribute :remarks, :string

      validates :whom, inclusion: { in: WHOM.keys, message: "must say whether the patient or the clinic cancelled" }
      validates :reason_ien, presence: { message: "is required" }
      validates :remarks, length: { in: 3..160 }, allow_blank: true

      def initialize(attrs = {})
        super
        self.remarks = remarks.to_s.strip.presence
      end
    end
  end
end
