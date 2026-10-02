# frozen_string_literal: true

module Lakeraven
  module EHR
    # What the scheduler enters to cancel an appointment (rpms-ux S-SCH-02),
    # and the rules that refuse it before anything reaches the broker: who
    # cancelled and a reason are required (S-SCH-02.2), remarks are 3 to 160
    # characters (S-SCH-02.3).
    class AppointmentCancellation
      include ActiveModel::Model
      include ActiveModel::Attributes

      CANCELLED_BY = %w[clinic patient].freeze

      attribute :appointment_ien, :integer
      attribute :cancelled_by, :string
      attribute :reason_ien, :integer
      attribute :remarks, :string

      validates :appointment_ien, :cancelled_by, :reason_ien, presence: true
      validates :cancelled_by, inclusion: { in: CANCELLED_BY }, allow_blank: true
      validates :remarks, length: { in: 3..160 }, allow_blank: true

      HUMAN_NAMES = {
        "appointment_ien" => "Appointment", "cancelled_by" => "Cancelled by",
        "reason_ien" => "Reason", "remarks" => "Remarks"
      }.freeze

      def self.human_attribute_name(attribute, options = {})
        HUMAN_NAMES.fetch(attribute.to_s) { super }
      end

      attr_reader :result

      def cancel(gateway: AppointmentBookingGateway)
        return false unless valid?

        @result = gateway.cancel(appointment_ien: appointment_ien, cancelled_by: cancelled_by,
                                 reason_ien: reason_ien, remarks: remarks.presence)
        return true if @result[:success]

        errors.add(:base, @result[:error])
        false
      end
    end
  end
end
