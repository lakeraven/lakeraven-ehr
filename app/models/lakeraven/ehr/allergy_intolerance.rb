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

      RXNORM_SYSTEM = "http://www.nlm.nih.gov/research/umls/rxnorm"
      VALID_CRITICALITIES = %w[low high unable-to-assess].freeze

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
          # A coded allergen carries its coding; the mapped RPC surface returns
          # text only, so the coding is present exactly when something upstream
          # could supply one.
          code: { coding: allergen_coding, text: allergen }.compact,
          criticality: fhir_criticality,
          patient: { reference: "Patient/#{patient_dfn}" },
          # FHIR JSON forbids empty arrays — omit reaction entirely when absent.
          reaction: reaction ? [ { manifestation: [ { text: reaction } ], severity: fhir_reaction_severity }.compact ] : nil
        }.compact
      end

      private

      # Required binding: an RxCUI is a numeric concept id. Emitting any
      # non-blank string under the RxNorm system publishes a coding that is not
      # an RxNorm code -- "not-rxnorm", or a whitespace-padded value a consumer
      # cannot look up -- and a wrong coding is worse than an absent one,
      # because a consumer trusts the system URI. Anything that is not an RxCUI
      # is dropped and the allergen survives as text.
      def allergen_coding
        rxcui = allergen_code.to_s.strip
        return nil unless rxcui.match?(/\A\d+\z/)

        [ { system: RXNORM_SYSTEM, code: rxcui, display: allergen }.compact ]
      end

      # Required binding: omit anything that is not a legal criticality code.
      def fhir_criticality
        normalized = criticality.to_s.strip.downcase
        VALID_CRITICALITIES.include?(normalized) ? normalized : nil
      end

      # Required binding: emit severity only when it normalizes to a legal code.
      def fhir_reaction_severity
        normalized = severity.to_s.strip.downcase
        VALID_REACTION_SEVERITIES.include?(normalized) ? normalized : nil
      end
    end
  end
end
