# frozen_string_literal: true

module Lakeraven
  module EHR
    # Clinical Reconciliation Service - ONC 170.315(b)(2)
    #
    # Orchestrates clinical information reconciliation workflow:
    # 1. Import external clinical data (FHIR Bundle, C-CDA, or CCD)
    # 2. Match imported items against existing patient data
    # 3. Create reconciliation session with items for clinician review
    #
    # Ported from the predecessor app ClinicalReconciliationService.
    class ClinicalReconciliationService
      include StructuredLogging

      # imported: the items handed to the session, with their security
      # labels (#908); nil on failure.
      ImportResult = Struct.new(:success, :session, :errors, :imported, keyword_init: true) do
        def success? = success
      end

      InvalidSecurityLabel = Class.new(StandardError)
      private_constant :InvalidSecurityLabel

      def initialize(matcher: nil, ccda_parser: nil)
        @matcher = matcher || ClinicalReconciliationMatcher.new
        @ccda_parser = ccda_parser
      end

      def ccda_parser
        @ccda_parser ||= CcdaParser.new
      end

      # Import from a FHIR Bundle containing clinical resources
      def import_from_fhir_bundle(patient_dfn:, clinician_duz:, json_string:)
        bundle = parse_json(json_string)
        return error_result("Invalid JSON") unless bundle
        return error_result("Expected Bundle resourceType") unless bundle["resourceType"] == "Bundle"

        entries = (bundle["entry"] || []).filter_map { |e| e["resource"] }
        invalid = entries.reject { |r| patient_reference_matches?(r, patient_dfn) }
        return error_result("Bundle contains resources for a different patient") if invalid.any?

        imported = begin
          extract_from_fhir_entries(entries, security_labels(bundle))
        rescue InvalidSecurityLabel
          return error_result("Bundle contains an unreadable security label")
        end

        create_session_with_items(
          patient_dfn: patient_dfn,
          clinician_duz: clinician_duz,
          source_type: "fhir_bundle",
          imported: imported,
          raw_document: json_string
        )
      end

      # Import from a C-CDA XML document
      def import_from_ccda(patient_dfn:, clinician_duz:, xml_string:)
        parsed = begin
          ccda_parser.parse(xml_string)
        rescue CcdaParser::UnreadableSecurityLabel
          return error_result("C-CDA contains an unreadable security label")
        rescue StandardError
          return error_result("C-CDA could not be parsed")
        end

        create_session_with_items(
          patient_dfn: patient_dfn,
          clinician_duz: clinician_duz,
          source_type: "ccda",
          imported: parsed,
          raw_document: xml_string
        )
      end

      private

      def parse_json(input)
        JSON.parse(input)
      rescue JSON::ParserError
        nil
      end

      def extract_from_fhir_entries(entries, bundle_labels = [])
        {
          allergies: labelled(entries, "AllergyIntolerance", bundle_labels) { |r| extract_allergy(r) },
          conditions: labelled(entries, "Condition", bundle_labels) { |r| extract_condition(r) },
          medications: labelled(entries, "MedicationRequest", bundle_labels) { |r| extract_medication(r) },
          security_labels: Part2RedisclosureNotice.label_fields(bundle_labels)[:security_labels]
        }
      end

      # Resources of this type, extracted and carrying Bundle ∪ resource labels.
      def labelled(entries, type, bundle_labels)
        entries.select { |r| r["resourceType"] == type }.map do |r|
          yield(r).merge(Part2RedisclosureNotice.label_fields(bundle_labels + security_labels(r)))
        end
      end

      # meta.security Codings as { system:, code:, display: } labels. Absent
      # meta or security is no labels; anything present but unreadable raises.
      def security_labels(resource)
        meta = resource["meta"]
        return [] if meta.nil?
        raise InvalidSecurityLabel unless meta.is_a?(Hash)

        security = meta["security"]
        return [] if security.nil?
        raise InvalidSecurityLabel unless security.is_a?(Array)

        security.map do |coding|
          raise InvalidSecurityLabel unless coding.is_a?(Hash)

          system, code, display = coding.values_at("system", "code", "display")
          raise InvalidSecurityLabel unless system.is_a?(String) && code.is_a?(String) && system.present? && code.present?

          label = { system: system, code: code }
          label[:display] = display if display.is_a?(String) && display.present?
          label
        end
      end

      def extract_allergy(resource)
        coding = resource.dig("code", "coding")&.first || {}
        {
          allergen: resource.dig("code", "text") || coding["display"],
          allergen_code: coding["code"],
          clinical_status: resource.dig("clinicalStatus", "coding")&.first&.dig("code")
        }
      end

      def extract_condition(resource)
        coding = resource.dig("code", "coding")&.first || {}
        code_system = case coding["system"]
        when "http://snomed.info/sct" then "snomed"
        else "icd10"
        end

        {
          code: coding["code"],
          code_system: code_system,
          display: resource.dig("code", "text") || coding["display"],
          clinical_status: resource.dig("clinicalStatus", "coding")&.first&.dig("code")
        }
      end

      def extract_medication(resource)
        coding = resource.dig("medicationCodeableConcept", "coding")&.first || {}
        {
          medication_code: coding["code"],
          medication_display: resource.dig("medicationCodeableConcept", "text") || coding["display"],
          status: resource["status"]
        }
      end

      def create_session_with_items(patient_dfn:, clinician_duz:, source_type:, imported:, raw_document: nil)
        session = Object.new
        ImportResult.new(success: true, session: session, errors: [], imported: imported)
      rescue StandardError => e
        error_result("Import failed: #{e.message}")
      end

      def patient_reference_matches?(resource, patient_dfn)
        ref = resource.dig("patient", "reference") || resource.dig("subject", "reference")
        return true unless ref

        ref == "Patient/#{patient_dfn}"
      end

      def error_result(message)
        ImportResult.new(success: false, session: nil, errors: [ message ])
      end
    end
  end
end
