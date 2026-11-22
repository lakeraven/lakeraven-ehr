# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#908 (slice of #522): a Part 2 labelled record keeps its
# label end to end through import. Uses the REAL CcdaParser. Synthetic data.
module Lakeraven
  module EHR
    class ClinicalReconciliationSecurityLabelsTest < ActiveSupport::TestCase
      CONF = "http://terminology.hl7.org/CodeSystem/v3-Confidentiality"
      ACT  = "http://terminology.hl7.org/CodeSystem/v3-ActCode"
      R_CODING     = { "system" => CONF, "code" => "R", "display" => "restricted" }.freeze
      PART2_CODING = { "system" => ACT, "code" => "42CFRPart2" }.freeze

      setup { @service = ClinicalReconciliationService.new }

      def resource(type, meta: nil)
        base = { "resourceType" => type, "subject" => { "reference" => "Patient/123" } }
        base["meta"] = meta if meta
        case type
        when "AllergyIntolerance" then base.merge("code" => { "text" => "Penicillin", "coding" => [ { "code" => "7980" } ] })
        when "Condition" then base.merge("code" => { "coding" => [ { "code" => "E11.9" } ] })
        else base.merge("status" => "active", "medicationCodeableConcept" => { "coding" => [ { "code" => "197361" } ] })
        end
      end

      def import_bundle(resources, meta: nil)
        bundle = { "resourceType" => "Bundle", "entry" => resources.map { |r| { "resource" => r } } }
        bundle["meta"] = meta if meta
        @service.import_from_fhir_bundle(patient_dfn: "123", clinician_duz: "301", json_string: bundle.to_json)
      end

      def import_ccda(header)
        xml = <<~XML
          <ClinicalDocument xmlns="urn:hl7-org:v3" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            #{header}
            <component><structuredBody><component><section>
              <templateId root="2.16.840.1.113883.10.20.22.2.5.1"/>
              <entry><act classCode="ACT" moodCode="EVN"><entryRelationship typeCode="SUBJ">
                <observation classCode="OBS" moodCode="EVN"><value xsi:type="CD" code="E11.9" displayName="Test condition"/></observation>
              </entryRelationship>
              <entryRelationship typeCode="COMP"><observation classCode="OBS" moodCode="EVN">
                <value xsi:type="CE" code="42CFRPart2" codeSystem="2.16.840.1.113883.5.4"/>
              </observation></entryRelationship></act></entry>
            </section></component></structuredBody></component>
          </ClinicalDocument>
        XML
        @service.import_from_ccda(patient_dfn: "123", clinician_duz: "301", xml_string: xml)
      end

      def pairs(labels) = labels.map { |l| [ l[:system], l[:code] ] }.sort

      test "FHIR: resource meta.security survives import and marks Part 2" do
        result = import_bundle([
          resource("AllergyIntolerance", meta: { "security" => [ R_CODING, PART2_CODING ] }),
          resource("Condition", meta: { "security" => [ PART2_CODING.merge("code" => "sud") ] }),
          resource("MedicationRequest")
        ])

        assert result.success?
        allergy = result.imported[:allergies].first
        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(allergy[:security_labels])
        assert_includes allergy[:security_labels], { system: CONF, code: "R", display: "restricted" }
        assert_includes allergy[:security_labels], { system: ACT, code: "42CFRPart2" }
        assert_equal true, allergy[:part2]
        assert_equal "7980", allergy[:allergen_code]

        condition = result.imported[:conditions].first
        assert_equal [ { system: ACT, code: "sud" } ], condition[:security_labels]
        assert_equal true, condition[:part2]

        medication = result.imported[:medications].first
        assert_equal [], medication[:security_labels]
        assert_equal false, medication[:part2]
        assert_equal [], result.imported[:security_labels]
      end

      test "FHIR: Bundle meta.security labels every item, unioned and de-duplicated with resource labels" do
        result = import_bundle(
          [ resource("Condition", meta: { "security" => [ PART2_CODING, R_CODING ] }), resource("MedicationRequest") ],
          meta: { "security" => [ PART2_CODING ] }
        )

        assert result.success?
        assert_equal [ { system: ACT, code: "42CFRPart2" } ], result.imported[:security_labels]
        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(result.imported[:conditions].first[:security_labels])
        assert_equal [ { system: ACT, code: "42CFRPart2" } ], result.imported[:medications].first[:security_labels]
        assert_equal true, result.imported[:medications].first[:part2]
      end

      {
        "meta.security is not an Array" => { "security" => PART2_CODING },
        "a Coding is not a Hash" => { "security" => [ "42CFRPart2" ] },
        "a Coding has no code" => { "security" => [ { "system" => ACT } ] },
        "a Coding has a blank code" => { "security" => [ { "system" => ACT, "code" => " " } ] }
      }.each do |label, meta|
        test "FHIR fail closed: import fails when #{label} (resource)" do
          result = import_bundle([ resource("Condition", meta: meta) ])

          refute result.success?, "malformed security label must fail the import, not be dropped"
          assert result.errors.any? { |e| e.match?(/security label/i) }, "errors: #{result.errors.inspect}"
          assert_nil result.imported
        end
      end

      test "FHIR fail closed: malformed Bundle meta.security fails the import" do
        result = import_bundle([ resource("Condition") ], meta: { "security" => "R" })

        refute result.success?
        assert result.errors.any? { |e| e.match?(/security label/i) }, "errors: #{result.errors.inspect}"
      end

      test "C-CDA: Part 2 label reaches the imported items via the real parser" do
        result = import_ccda(%(<confidentialityCode code="R" codeSystem="2.16.840.1.113883.5.25"/>))

        assert result.success?
        assert_equal [ { system: CONF, code: "R" } ], result.imported[:security_labels]
        condition = result.imported[:conditions].first
        assert_equal "E11.9", condition[:code]
        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(condition[:security_labels])
        assert_equal true, condition[:part2]
      end

      test "C-CDA fail closed: unreadable confidentialityCode fails the import with an error" do
        result = import_ccda(%(<confidentialityCode nullFlavor="NI"/>))

        refute result.success?, "unreadable confidentialityCode must fail the import, not be dropped"
        assert result.errors.any?(&:present?)
        assert_nil result.imported
      end

      test "imported is nil on an unrelated failure" do
        result = @service.import_from_fhir_bundle(patient_dfn: "123", clinician_duz: "301", json_string: "not-json")

        refute result.success?
        assert_respond_to result, :imported
        assert_nil result.imported
      end
    end
  end
end
