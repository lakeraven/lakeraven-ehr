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

      # Extracted resource types: resourceType => [result key, extractor].
      EXTRACTORS = {
        "AllergyIntolerance" => [ :allergies, :extract_allergy ],
        "Condition" => [ :conditions, :extract_condition ],
        "MedicationRequest" => [ :medications, :extract_medication ]
      }.freeze
      UNREADABLE = Part2RedisclosureNotice::UNREADABLE

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
        return error_result("Expected Bundle resourceType") unless bundle.is_a?(Hash) && bundle["resourceType"] == "Bundle"

        entries, bundle_marks = bundle_contents(bundle)
        invalid = entries.reject { |r| patient_reference_matches?(r, patient_dfn) }
        return error_result("Bundle contains resources for a different patient") if invalid.any?

        imported = extract_from_fhir_entries(entries, bundle_marks)

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
        rescue StandardError => e
          log_warn("ccda_import_parse_failed", error: e.class.name)
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
        JSON.parse(input, allow_duplicate_key: false)
      rescue JSON::ParserError
        nil
      end

      # Hash resources of the Bundle, and the Bundle-level marks: labels on
      # the Bundle itself and its entry wrappers, and UNREADABLE for an entry
      # list, entry or resource that is not the right JSON type.
      def bundle_contents(bundle)
        marks = label_marks(bundle.except("entry"))
        entries = bundle["entry"]
        return [ [], marks ] if entries.nil?
        return [ [], marks << UNREADABLE ] unless entries.is_a?(Array)

        resources = []
        entries.each do |entry|
          resource = entry["resource"] if entry.is_a?(Hash)
          marks.concat(label_marks(entry.except("resource"))) if entry.is_a?(Hash)
          if resource.is_a?(Hash) then resources << resource
          elsif !(entry.is_a?(Hash) && resource.nil?) then marks << UNREADABLE
          end
        end
        [ resources, marks ]
      end

      # Each extracted item carries the marks at any depth of its resource
      # plus the Bundle's; marks on other resources belong to the Bundle.
      def extract_from_fhir_entries(entries, bundle_marks = [])
        marked = entries.map { |r| [ r, label_marks(r) ] }
        extracted, others = marked.partition { |r, _| EXTRACTORS.key?(r["resourceType"]) }
        bundle_marks += others.flat_map(&:last)

        merge = Part2RedisclosureNotice.inheriting(bundle_marks)
        items = EXTRACTORS.values.to_h { |key, _| [ key, [] ] }
        extracted.each do |resource, marks|
          key, extractor = EXTRACTORS[resource["resourceType"]]
          items[key] << send(extractor, resource).merge(merge.call(marks))
        end
        top = merge.call(extracted.flat_map(&:last))
        items.merge(security_labels: merge.call([])[:security_labels], part2: top[:part2])
      end

      # Label marks at any depth: meta.security Codings, securityLabel
      # CodeableConcepts (and Part 2 codes nested inside either), any Coding
      # whose code is a Part 2 code, and a Part 2 primitive valueCode.
      def label_marks(node)
        case node
        when Array then node.flat_map { |value| label_marks(value) }
        when Hash
          marks = []
          marks.concat(meta_marks(node["meta"])) if node.key?("meta")
          marks.concat(security_label_marks(node["securityLabel"])) if node.key?("securityLabel")
          marks << coding_mark(node) if node["code"].is_a?(String) && Part2RedisclosureNotice.part2_code?(node["code"])
          marks << { code: node["valueCode"] } if node["valueCode"].is_a?(String) && Part2RedisclosureNotice.part2_code?(node["valueCode"])
          marks + node.except("meta", "securityLabel").values.flat_map { |value| label_marks(value) }
        else []
        end
      end

      def meta_marks(meta)
        return [] if meta.nil?
        return [ UNREADABLE ] unless meta.is_a?(Hash)

        security = meta["security"]
        others = label_marks(meta.except("security"))
        return others if security.nil?
        return others << UNREADABLE unless security.is_a?(Array)

        others + security.flat_map { |coding| coding_marks(coding) }
      end

      def security_label_marks(concepts)
        return [] if concepts.nil?
        return [ UNREADABLE ] unless concepts.is_a?(Array)

        concepts.flat_map do |concept|
          next [ UNREADABLE ] unless concept.is_a?(Hash)

          codings = concept["coding"]
          own = codings.is_a?(Array) && codings.any? ? codings.flat_map { |coding| coding_marks(coding) } : [ UNREADABLE ]
          own + label_marks(concept.except("coding"))
        end
      end

      # A label Coding's own mark plus the marks nested in its children.
      def coding_marks(coding)
        children = coding.is_a?(Hash) ? label_marks(coding.values) : []
        [ coding_mark(coding), *children ]
      end

      # A Coding as { system:, code:, display: } (system and display only
      # when present), or UNREADABLE.
      def coding_mark(coding)
        return UNREADABLE unless coding.is_a?(Hash)

        system, code, display = coding.values_at("system", "code", "display")
        return UNREADABLE unless code.is_a?(String) && Part2RedisclosureNotice.unpad(code).present?
        return UNREADABLE unless system.nil? || (system.is_a?(String) && system.present?)

        label = { system: system, code: code }.compact
        label[:display] = display if display.is_a?(String) && display.present?
        label
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
