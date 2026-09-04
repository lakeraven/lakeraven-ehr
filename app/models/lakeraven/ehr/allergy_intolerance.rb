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

      # Build AllergyIntolerance instances from raw ORQQAL LIST hashes
      # ({ allergen:, reaction:, severity: }).
      #
      # The wire carries no IEN, so the id derives DETERMINISTICALLY from
      # dfn + allergen (mirroring Observation.vital_id) — never a random
      # uuid. ORQQAL LIST returns the active allergy list, so
      # clinical_status keeps its "active" default; the wire carries no
      # criticality or allergen code (a deployment that can source those —
      # e.g. a synthetic-sandbox fixture set — supplies them through
      # Configuration#supplemental_allergy_intolerances_provider).
      def self.from_rpc_hashes(hashes, patient_dfn:)
        Array(hashes).map do |h|
          new(
            ien: allergy_id(patient_dfn, h),
            patient_dfn: patient_dfn.to_s,
            allergen: h[:allergen],
            reaction: h[:reaction],
            severity: h[:severity]
          )
        end
      end

      def self.allergy_id(patient_dfn, hash)
        slug = hash[:allergen].to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
        "allergy-#{patient_dfn}-#{slug}"
      end
      private_class_method :allergy_id

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

      # AllergyIntolerance.criticality has a REQUIRED binding too.
      VALID_CRITICALITIES = %w[low high unable-to-assess].freeze

      CLINICAL_STATUS_SYSTEM = "http://terminology.hl7.org/CodeSystem/allergyintolerance-clinical"
      RXNORM_SYSTEM = "http://www.nlm.nih.gov/research/umls/rxnorm"

      def to_fhir
        {
          resourceType: "AllergyIntolerance",
          id: ien&.to_s,
          clinicalStatus: { coding: [ { system: CLINICAL_STATUS_SYSTEM, code: clinical_status } ] },
          criticality: fhir_criticality,
          code: build_code,
          patient: { reference: "Patient/#{patient_dfn}" },
          # FHIR JSON forbids empty arrays — omit reaction entirely when absent.
          reaction: reaction ? [ { manifestation: [ { text: reaction } ], severity: fhir_reaction_severity }.compact ] : nil
        }.compact
      end

      private

      # allergen_code is RxNorm when present (see #matching_key); the wire
      # path carries none, so text-only codes are the norm there.
      def build_code
        result = { text: allergen }.compact # never emit "text": null
        if allergen_code.present?
          result[:coding] = [ { system: RXNORM_SYSTEM, code: allergen_code, display: allergen }.compact ]
        end
        result
      end

      # Required binding: emit criticality only when it is a legal code.
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
