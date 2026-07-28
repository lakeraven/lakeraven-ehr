# frozen_string_literal: true

module Lakeraven
  module EHR
    class AllergyIntolerance
      include ActiveModel::Model
      include ActiveModel::Attributes

      US_CORE_ALLERGY_PROFILE = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-allergyintolerance"
      CLINICAL_STATUS_SYSTEM = "http://terminology.hl7.org/CodeSystem/allergyintolerance-clinical"
      VALID_REACTION_SEVERITIES = %w[mild moderate severe].freeze

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

      # Build AllergyIntolerance instances from raw allergy rows and return
      # them ready for FHIR serialization. Rows come from ORQQAL LIST on
      # both backends: { allergen:, reaction:, severity:, allergy_ien: }.
      def self.fhir_for_patient(dfn)
        from_allergy_hashes(gateway.for_patient(dfn), patient_dfn: dfn)
      end

      def self.from_allergy_hashes(hashes, patient_dfn:)
        hashes.map do |h|
          new(
            ien: h[:allergy_ien]&.to_s,
            patient_dfn: patient_dfn.to_s,
            allergen: h[:allergen],
            reaction: h[:reaction].presence,
            severity: normalize_reaction_severity(h[:severity]),
            clinical_status: "active"
          )
        end
      end

      # FHIR reaction.severity is a required-binding code (mild | moderate |
      # severe); drop anything the wire sends that doesn't normalize to it.
      def self.normalize_reaction_severity(value)
        normalized = value.to_s.downcase.strip
        VALID_REACTION_SEVERITIES.include?(normalized) ? normalized : nil
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

      def to_fhir
        resource = {
          resourceType: "AllergyIntolerance",
          id: ien&.to_s,
          meta: build_meta,
          clinicalStatus: { coding: [ { code: clinical_status, system: CLINICAL_STATUS_SYSTEM } ] },
          code: { text: allergen },
          patient: { reference: "Patient/#{patient_dfn}" },
          reaction: reaction ? [ { manifestation: [ { text: reaction } ], severity: severity }.compact ] : []
        }.compact

        Lakeraven::EHR::FHIR::UsCoreValidator.validate!(resource) if Lakeraven::EHR.configuration.validate_fhir_us_core

        resource
      end

      private

      # Claim US Core conformance only when the profile's required elements
      # are present (same conditional-claim pattern as Observation/Condition).
      def build_meta
        return nil unless ien.present? && patient_dfn.present? && allergen.present?

        { profile: [ US_CORE_ALLERGY_PROFILE ] }
      end
    end
  end
end
