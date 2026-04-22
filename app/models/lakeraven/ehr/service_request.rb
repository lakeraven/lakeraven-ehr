# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequest
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :integer
      attribute :patient_dfn, :integer
      attribute :identifier, :string
      attribute :referral_type, :string
      attribute :requesting_provider_ien, :integer
      attribute :performer_name, :string

      def self.for_patient(dfn)
        ServiceRequestGateway.for_patient(dfn)
      end



      def to_fhir
        {
          resourceType: "ServiceRequest",
          id: ien&.to_s,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          status: respond_to?(:status) ? status : nil
        }.compact
      end
    end
  end
end
