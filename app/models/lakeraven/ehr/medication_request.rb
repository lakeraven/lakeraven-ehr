# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequest
      include ActiveModel::Model
      include ActiveModel::Attributes

      VALID_STATUSES = %w[active on-hold cancelled completed stopped draft entered-in-error unknown].freeze
      VALID_INTENTS = %w[proposal plan order original-order reflex-order filler-order instance-order option].freeze
      DATA_ABSENT_REASON = "http://hl7.org/fhir/StructureDefinition/data-absent-reason"

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

      # ORQQPS LIST is ID^NAME+FORM^STOP_DATE^ROUTE^SCHEDULE^REFILLS.
      # Status is mapped only when a row actually carries one. stop_date
      # is never a status. No code, authoredOn, or requester on this wire.
      RPMS_STATUS = {
        "discontinued" => "stopped",
        "dc" => "stopped",
        "expired" => "completed",
        "hold" => "on-hold",
        "pending" => "draft",
        "active" => "active"
      }.freeze

      def self.from_rpms_row(row, patient_dfn:)
        new(
          ien: row[:ien]&.to_s,
          patient_dfn: patient_dfn,
          medication_display: row[:drug_name],
          dosage_instruction: dosage_text(row),
          status: rpms_status(row[:status]),
          intent: "order"
        )
      end

      # Case-insensitive. Blank and unrecognised RPMS text are unknown,
      # which is a legal MedicationRequest status. Do not pass a raw
      # FHIR code through, and do not read stop_date.
      def self.rpms_status(raw)
        RPMS_STATUS[raw.to_s.strip.downcase] || "unknown"
      end

      # dosageInstruction.text is route + schedule when either is present.
      # A sig is not on the ORQQPS LIST wire; keep one only when this row
      # carries it and the wire fields are blank.
      def self.dosage_text(row)
        parts = [ row[:route], row[:schedule] ].filter_map { |part| part.to_s.strip.presence }
        return parts.join(" ") if parts.any?

        row[:sig].to_s.strip.presence
      end
      private_class_method :rpms_status, :dosage_text

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

      # SHA-256 of order content for audit trail integrity.
      def signed_content_hash
        require "digest"
        Digest::SHA256.hexdigest(
          [ ien, patient_dfn, medication_code, medication_display,
           dosage_instruction, route, frequency,
           dispense_quantity, refills, days_supply ].map(&:to_s).join("|")
        )
      end

      # Matching key for clinical reconciliation (ONC § 170.315(b)(2))
      def matching_key
        if medication_code.present?
          "rxnorm:#{medication_code}"
        elsif medication_display.present?
          "name:#{medication_display.downcase.strip}"
        end
      end

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
          authoredOn: authored_on&.iso8601,
          _authoredOn: build_authored_on_absent,
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

      def build_authored_on_absent
        return nil if authored_on.present?

        { extension: [ { url: DATA_ABSENT_REASON, valueCode: "unknown" } ] }
      end

      def build_requester
        if requester_duz.present?
          {
            reference: "Practitioner/#{requester_duz}",
            display: requester_name
          }.compact
        else
          { extension: [ { url: DATA_ABSENT_REASON, valueCode: "unknown" } ] }
        end
      end
    end
  end
end
