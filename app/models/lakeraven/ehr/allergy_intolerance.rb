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

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || AllergyIntoleranceGateway
        end
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      def active? = clinical_status == "active"
      def medication? = category == "medication"
      def food? = category == "food"

      # Matching key for clinical reconciliation (ONC § 170.315(b)(2))
      def matching_key
        if allergen_code.present?
          "rxnorm:#{allergen_code}"
        elsif allergen.present?
          "name:#{allergen.downcase.strip}"
        end
      end

      # AllergyIntolerance.reaction.severity has a REQUIRED binding.
      VALID_REACTION_SEVERITIES = %w[mild moderate severe].freeze

      CLINICAL_STATUS_SYSTEM = "http://terminology.hl7.org/CodeSystem/allergyintolerance-clinical"

      def to_fhir
        {
          resourceType: "AllergyIntolerance",
          id: ien&.to_s,
          clinicalStatus: { coding: [ { system: CLINICAL_STATUS_SYSTEM, code: clinical_status } ] },
          code: { text: allergen },
          patient: { reference: "Patient/#{patient_dfn}" },
          # FHIR JSON forbids empty arrays — omit reaction entirely when absent.
          reaction: reaction ? [ { manifestation: [ { text: reaction } ], severity: fhir_reaction_severity }.compact ] : nil
        }.compact
      end

      private

      # Required binding: emit severity only when it normalizes to a legal code.
      def fhir_reaction_severity
        normalized = severity.to_s.strip.downcase
        VALID_REACTION_SEVERITIES.include?(normalized) ? normalized : nil
      end
    end
  end
end
