# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR DetectedIssue resource - ActiveModel
    # Represents a clinical issue detected during drug interaction checking.
    # Maps to FHIR R4 DetectedIssue per ONC 170.315(a)(4).
    class DetectedIssue
      include ActiveModel::Model
      include ActiveModel::Attributes

      US_CORE_PROFILE = "http://hl7.org/fhir/StructureDefinition/DetectedIssue"

      VALID_STATUSES = %w[preliminary final amended corrected cancelled entered-in-error].freeze
      VALID_SEVERITIES = %w[high moderate low].freeze
      VALID_CODES = %w[drug-drug drug-allergy].freeze

      attribute :status, :string
      attribute :severity, :string
      attribute :code, :string
      attribute :detail, :string

      attr_accessor :implicated_items

      def initialize(attributes = {})
        items = attributes.delete(:implicated_items) || []
        super(attributes)
        @implicated_items = items
      end

      validates :status, presence: true, inclusion: { in: VALID_STATUSES }
      validates :severity, inclusion: { in: VALID_SEVERITIES, allow_blank: true }
      validates :code, presence: true, inclusion: { in: VALID_CODES }

      # Build from an InteractionAlert value object
      def self.from_interaction_alert(alert)
        new(
          status: "final",
          severity: alert.severity.to_s,
          code: alert.interaction_type == :drug_allergy ? "drug-allergy" : "drug-drug",
          detail: "#{alert.drug_a} + #{alert.drug_b}: #{alert.description}",
          implicated_items: [
            { display: alert.drug_a, reference: nil },
            { display: alert.drug_b, reference: nil }
          ]
        )
      end

      def to_fhir
        {
          resourceType: "DetectedIssue",
          meta: { profile: [ US_CORE_PROFILE ] },
          status: status,
          severity: severity,
          code: build_code,
          detail: detail,
          implicated: build_implicated
        }
      end

      def self.resource_class
        "DetectedIssue"
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          status: fhir_resource.status,
          severity: fhir_resource.severity,
          code: fhir_resource.code&.coding&.first&.code,
          detail: fhir_resource.detail
        }
      end

      private

      def build_code
        display = case code
        when "drug-drug" then "Drug-drug interaction"
        when "drug-allergy" then "Drug-allergy interaction"
        else code
        end

        {
          coding: [ {
            system: "http://terminology.hl7.org/CodeSystem/v3-ActCode",
            code: code,
            display: display
          } ]
        }
      end

      def build_implicated
        return [] unless implicated_items.is_a?(Array)
        implicated_items.map do |item|
          { display: item[:display], reference: item[:reference] }
        end
      end
    end
  end
end
