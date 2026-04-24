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

      # Clinical fields (ported from rpms_redux)
      attribute :service_requested, :string
      attribute :reason_for_referral, :string
      attribute :urgency, :string
      attribute :status, :string
      attribute :estimated_cost, :float
      attribute :diagnosis_codes, :string
      attribute :procedure_codes, :string
      attribute :medical_priority_level, :integer

      def self.for_patient(dfn)
        ServiceRequestGateway.for_patient(dfn)
      end

      # -- Urgency predicates ------------------------------------------------

      def emergent?
        urgency == "EMERGENT"
      end

      def urgent?
        urgency == "URGENT"
      end

      def routine?
        urgency.blank? || urgency == "ROUTINE"
      end

      # -- FHIR serialization ------------------------------------------------

      def to_fhir
        {
          resourceType: "ServiceRequest",
          id: ien&.to_s,
          status: status,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil
        }.compact
      end
    end
  end
end
