# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequest
      include ActiveModel::Model
      include ActiveModel::Attributes

      VALID_STATUSES = %w[active on-hold cancelled completed stopped draft entered-in-error].freeze
      VALID_INTENTS = %w[proposal plan order original-order reflex-order filler-order instance-order option].freeze

      attribute :ien, :string
      attribute :patient_dfn, :string
      attribute :medication_code, :string
      attribute :medication_display, :string
      attribute :status, :string
      attribute :intent, :string
      attribute :dosage_instruction, :string
      attribute :dose_quantity, :string
      attribute :dose_unit, :string
      attribute :route, :string
      attribute :frequency, :string
      attribute :authored_on, :datetime
      attribute :requester_duz, :string
      attribute :requester_name, :string
      attribute :dispense_quantity, :integer
      attribute :dispense_unit, :string
      attribute :refills, :integer
      attribute :days_supply, :integer

      validates :patient_dfn, presence: true
      validates :medication_display, presence: true
      validates :status, inclusion: { in: VALID_STATUSES, allow_blank: true }
      validates :intent, inclusion: { in: VALID_INTENTS, allow_blank: true }

      # -- Gateway DI -----------------------------------------------------------

      class << self
        attr_writer :gateway

        def gateway
          @gateway || MedicationRequestGateway
        end
      end

      def self.for_patient(dfn)
        gateway.for_patient(dfn)
      end

      def self.resource_class
        "MedicationRequest"
      end

      def self.from_fhir_attributes(fhir_resource)
        {
          medication_code: fhir_resource.medicationCodeableConcept&.coding&.first&.code,
          medication_display: fhir_resource.medicationCodeableConcept&.text ||
                              fhir_resource.medicationCodeableConcept&.coding&.first&.display,
          status: fhir_resource.status,
          intent: fhir_resource.intent
        }
      end

      def active? = status == "active"

      def persisted?
        ien.present?
      end

      def to_fhir
        {
          resourceType: "MedicationRequest",
          id: ien&.to_s,
          status: status,
          intent: intent,
          subject: patient_dfn ? { reference: "Patient/#{patient_dfn}" } : nil,
          medicationCodeableConcept: build_medication_code,
          dosageInstruction: build_dosage_instructions,
          dispenseRequest: build_dispense_request,
          requester: build_requester
        }.compact
      end

      private

      def build_medication_code
        return nil unless medication_code || medication_display

        result = {}
        if medication_code
          result[:coding] = [ {
            system: "http://www.nlm.nih.gov/research/umls/rxnorm",
            code: medication_code,
            display: medication_display
          }.compact ]
        end
        result[:text] = medication_display if medication_display
        result
      end

      def build_dosage_instructions
        return nil if dosage_instruction.blank? && dose_quantity.blank?

        instruction = { text: dosage_instruction }
        instruction[:route] = { text: route } if route.present?
        instruction[:timing] = { code: { text: frequency } } if frequency.present?

        [ instruction ]
      end

      def build_dispense_request
        return nil if dispense_quantity.blank? && refills.blank? && days_supply.blank?

        dr = {}
        dr[:numberOfRepeatsAllowed] = refills if refills.present?
        if dispense_quantity.present?
          dr[:quantity] = { value: dispense_quantity, unit: dispense_unit || "each" }
        end
        if days_supply.present?
          dr[:expectedSupplyDuration] = {
            value: days_supply, unit: "days",
            system: "http://unitsofmeasure.org", code: "d"
          }
        end
        dr
      end

      def build_requester
        return nil if requester_duz.blank?

        {
          reference: "Practitioner/#{requester_duz}",
          display: requester_name
        }.compact
      end
    end
  end
end
