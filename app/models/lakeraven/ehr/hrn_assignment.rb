# frozen_string_literal: true

module Lakeraven
  module EHR
    # A health record number given to a patient at this facility (rpms-ux
    # S-REG-06): 1 to 6 characters in the chart-number form, filed only when
    # the patient has none here yet (S-REG-06.2).
    class HrnAssignment
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :hrn, :string

      validates :hrn, presence: true, format: { with: /\A[0-9A-Z]{1,6}\z/i, message: "must be 1 to 6 letters or digits" }

      def self.human_attribute_name(attribute, options = {})
        attribute.to_s == "hrn" ? "Health record number" : super
      end

      def file(dfn:, facility_ien:, gateway: PatientRegistrationGateway)
        return false unless valid?

        if facility_ien.to_i <= 0
          errors.add(:base, "Your facility could not be read from RPMS, so no chart number can be filed")
          return false
        end
        if gateway.hrn(dfn, facility_ien).present?
          errors.add(:base, "This patient is already registered at this facility")
          return false
        end

        result = gateway.file_hrn(dfn: dfn, facility_ien: facility_ien, hrn: hrn.upcase)
        return true if result[:success]

        errors.add(:base, result[:error])
        false
      end
    end
  end
end
