# frozen_string_literal: true

module Lakeraven
  module EHR
    # Clinical Reconciliation Matcher
    #
    # Compares imported clinical items against existing patient records
    # to determine match status (new, duplicate, or conflict).
    #
    # Matching strategy per resource type:
    #   - Allergies: RxNorm code match, then normalized allergen name
    #   - Conditions: ICD-10/SNOMED code match, then normalized display text
    #   - Medications: RxNorm code match, then normalized drug name
    #
    # ONC § 170.315(b)(2) - Clinical Information Reconciliation
    # Ported from rpms_redux ClinicalReconciliationMatcher.
    class ClinicalReconciliationMatcher
      # Match imported items against existing records
      #
      # @param imported_items [Array<Hash>] Items extracted from external document
      # @param existing_records [Array] ActiveModel instances from current patient data
      # @param resource_type [String] "AllergyIntolerance", "Condition", "MedicationRequest"
      # @return [Array<Hash>] Items with :match_status and :internal_record added
      def match(imported_items, existing_records, resource_type:)
        return [] if imported_items.empty?

        index = build_matching_index(existing_records)

        imported_items.map do |item|
          imported_key = compute_matching_key(item, resource_type)
          matched = index[imported_key] if imported_key

          if matched
            status = status_differs?(item, matched, resource_type) ? "conflict" : "duplicate"
            {
              imported: item,
              match_status: status,
              internal_record: { ien: matched.ien }
            }
          else
            { imported: item, match_status: "new", internal_record: nil }
          end
        end
      end

      private

      def build_matching_index(existing_records)
        index = {}
        existing_records.each do |record|
          key = record.matching_key
          index[key] = record if key.present?
        end
        index
      end

      def compute_matching_key(item, resource_type)
        case resource_type
        when "AllergyIntolerance"
          allergy_key(item)
        when "Condition"
          condition_key(item)
        when "MedicationRequest"
          medication_key(item)
        end
      end

      def allergy_key(item)
        if item[:allergen_code].present?
          "rxnorm:#{item[:allergen_code]}"
        elsif item[:allergen].present?
          "name:#{item[:allergen].downcase.strip}"
        end
      end

      def condition_key(item)
        if item[:code].present?
          system = item[:code_system] || "icd10"
          "#{system}:#{item[:code]}"
        elsif item[:display].present?
          "name:#{item[:display].downcase.strip}"
        end
      end

      def medication_key(item)
        if item[:medication_code].present?
          "rxnorm:#{item[:medication_code]}"
        elsif item[:medication_display].present?
          "name:#{item[:medication_display].downcase.strip}"
        end
      end

      def status_differs?(imported, existing, resource_type)
        case resource_type
        when "AllergyIntolerance"
          imported[:clinical_status].present? &&
            existing.clinical_status.present? &&
            imported[:clinical_status] != existing.clinical_status
        when "Condition"
          imported[:clinical_status].present? &&
            existing.clinical_status.present? &&
            imported[:clinical_status] != existing.clinical_status
        when "MedicationRequest"
          imported[:status].present? &&
            existing.status.present? &&
            imported[:status] != existing.status
        else
          false
        end
      end
    end
  end
end
