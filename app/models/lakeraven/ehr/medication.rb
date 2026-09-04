# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 Medication — a definitional drug resource (RxNorm-coded),
    # independently readable so consumers can resolve what was prescribed.
    # Backed by the in-memory MedicationStore (no mapped RPMS RPC exposes
    # the DRUG file); serialization follows the Condition/Observation
    # pattern (to_fhir on the model).
    class Medication
      include ActiveModel::Model
      include ActiveModel::Attributes
      include ActiveModel::Validations

      VALID_STATUSES = %w[active inactive entered-in-error].freeze

      RXNORM_SYSTEM = "http://www.nlm.nih.gov/research/umls/rxnorm"

      attribute :fhir_id, :string
      attribute :code, :string
      attribute :code_system, :string, default: "rxnorm"
      attribute :display, :string
      attribute :form, :string
      attribute :status, :string, default: "active"

      validates :fhir_id, presence: true
      validates :display, presence: true
      validates :status, inclusion: { in: VALID_STATUSES }

      def self.resource_class
        "Medication"
      end

      def active? = status == "active"
      def persisted? = fhir_id.present?

      def to_fhir
        {
          resourceType: "Medication",
          id: fhir_id,
          status: status,
          code: build_code,
          form: form ? { text: form } : nil
        }.compact
      end

      private

      def build_code
        return nil unless code || display

        result = {}
        if code
          result[:coding] = [ {
            system: code_system == "rxnorm" ? RXNORM_SYSTEM : nil,
            code: code,
            display: display
          }.compact ]
        end
        result[:text] = display if display
        result
      end
    end
  end
end
