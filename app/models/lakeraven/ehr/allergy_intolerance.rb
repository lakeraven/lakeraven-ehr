# frozen_string_literal: true

module Lakeraven
  module EHR
    class AllergyIntolerance
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :allergen, :string
      attribute :allergen_code, :string
      attribute :reaction, :string
      attribute :severity, :string
      attribute :clinical_status, :string, default: "active"
      attribute :category, :string
      attribute :criticality, :string

      def self.for_patient(dfn)
        AllergyIntoleranceGateway.for_patient(dfn)
      end

      def self.from_fhir(hash)
        h = hash.transform_keys(&:to_s)
        patient_ref = h.dig("patient", "reference") || h.dig("subject", "reference")
        new(
          ien: h["id"],
          patient_dfn: patient_ref&.delete_prefix("Patient/"),
          allergen: h.dig("code", "text"),
          allergen_code: h.dig("code", "coding", 0, "code"),
          clinical_status: h.dig("clinicalStatus", "coding", 0, "code"),
          category: Array(h["category"]).first,
          criticality: h["criticality"],
          reaction: h.dig("reaction", 0, "manifestation", 0, "text"),
          severity: h.dig("reaction", 0, "severity")
        )
      end

      def active? = clinical_status == "active"
      def medication? = category == "medication"
      def food? = category == "food"

      def to_fhir
        {
          resourceType: "AllergyIntolerance",
          clinicalStatus: { coding: [ { code: clinical_status } ] },
          code: { text: allergen },
          patient: { reference: "Patient/#{patient_dfn}" },
          reaction: reaction ? [ { manifestation: [ { text: reaction } ], severity: severity } ] : []
        }.compact
      end
    end
  end
end
