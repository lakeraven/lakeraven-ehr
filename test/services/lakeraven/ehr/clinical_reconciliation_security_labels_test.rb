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

      def ccda_xml(header)
        <<~XML
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
      end

      def import_ccda(header, xml: ccda_xml(header))
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
        assert_equal true, result.imported[:part2], "top-level part2 is true when any label anywhere is Part 2"
      end

      test "FHIR: bundle with no labels anywhere is not Part 2 at any level" do
        result = import_bundle([ resource("Condition"), resource("MedicationRequest", meta: { "security" => [ R_CODING ] }) ])

        assert result.success?
        assert_equal false, result.imported[:part2]
        assert_equal false, result.imported[:conditions].first[:part2]
        assert_equal false, result.imported[:medications].first[:part2]
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

      # Rule A: an unreadable label is a marker (suspected Part 2), never a block.
      {
        "meta is not a Hash" => "restricted",
        "meta.security is not an Array" => { "security" => PART2_CODING },
        "a Coding is not a Hash" => { "security" => [ "42CFRPart2" ] },
        "a Coding has no code" => { "security" => [ { "system" => ACT } ] },
        "a Coding has a blank code" => { "security" => [ { "system" => ACT, "code" => " " } ] },
        "a Coding has a non-String code" => { "security" => [ { "system" => ACT, "code" => 42 } ] }
      }.each do |label, meta|
        test "FHIR: import succeeds and the resource is marked Part 2 when #{label}" do
          result = import_bundle([ resource("Condition", meta: meta), resource("MedicationRequest") ])

          assert result.success?, "an unreadable security label must not reject the import: #{result.errors.inspect}"
          assert_equal [], result.imported[:conditions].first[:security_labels], "no label value may be invented"
          assert_equal true, result.imported[:conditions].first[:part2]
          assert_equal false, result.imported[:medications].first[:part2]
          assert_equal true, result.imported[:part2]
        end
      end

      test "FHIR: unreadable Bundle meta.security marks every item Part 2 without rejecting" do
        result = import_bundle([ resource("Condition"), resource("AllergyIntolerance") ], meta: { "security" => "R" })

        assert result.success?, result.errors.inspect
        assert_equal [], result.imported[:security_labels]
        assert_equal true, result.imported[:part2]
        assert_equal true, result.imported[:conditions].first[:part2]
        assert_equal true, result.imported[:allergies].first[:part2]
      end

      test "FHIR: a readable label is kept alongside an unreadable one" do
        result = import_bundle([ resource("Condition", meta: { "security" => [ R_CODING, { "system" => CONF } ] }) ])

        assert result.success?, result.errors.inspect
        assert_equal [ [ CONF, "R" ] ], pairs(result.imported[:conditions].first[:security_labels])
        assert_equal true, result.imported[:conditions].first[:part2]
      end

      test "FHIR: Coding with a code but no system is kept as { code: } and counts for Part 2" do
        result = import_bundle([ resource("Condition", meta: { "security" => [ { "code" => "42CFRPart2" } ] }) ])

        assert result.success?, result.errors.inspect
        assert_equal [ { code: "42CFRPart2" } ], result.imported[:conditions].first[:security_labels]
        assert_equal true, result.imported[:conditions].first[:part2]
      end

      # Rule C: no label is lost by position.
      test "FHIR: labels at any depth of an extracted resource belong to that item" do
        inline = { "url" => "http://hl7.org/fhir/uv/security-label-ds4p/StructureDefinition/extension-inline-sec-label",
                   "valueCoding" => PART2_CODING }
        result = import_bundle([
          resource("AllergyIntolerance").merge("contained" => [ { "resourceType" => "Observation", "id" => "o1", "meta" => { "security" => [ PART2_CODING ] } } ]),
          resource("Condition").merge("extension" => [ inline ]),
          resource("MedicationRequest").merge("contained" => [ { "resourceType" => "DocumentReference", "id" => "d1", "securityLabel" => [ { "coding" => [ R_CODING ] } ] } ])
        ])

        assert result.success?, result.errors.inspect
        assert_equal [ { system: ACT, code: "42CFRPart2" } ], result.imported[:allergies].first[:security_labels]
        assert_equal true, result.imported[:allergies].first[:part2]
        assert_equal [ { system: ACT, code: "42CFRPart2" } ], result.imported[:conditions].first[:security_labels]
        assert_equal true, result.imported[:conditions].first[:part2]
        assert_equal [ { system: CONF, code: "R", display: "restricted" } ], result.imported[:medications].first[:security_labels]
        assert_equal false, result.imported[:medications].first[:part2]
        assert_equal [], result.imported[:security_labels]
        assert_equal true, result.imported[:part2]
      end

      test "FHIR: labels on non-extracted entries belong to the Bundle and reach every item" do
        composition = { "resourceType" => "Composition", "subject" => { "reference" => "Patient/123" }, "meta" => { "security" => [ PART2_CODING ] } }
        nested = { "resourceType" => "Bundle", "type" => "collection", "meta" => { "security" => [ R_CODING ] } }
        result = import_bundle([ composition, nested, resource("Condition"), resource("MedicationRequest") ])
        expected = [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ]

        assert result.success?, result.errors.inspect
        assert_equal expected, pairs(result.imported[:security_labels])
        assert_equal true, result.imported[:part2]
        [ result.imported[:conditions].first, result.imported[:medications].first ].each do |item|
          assert_equal expected, pairs(item[:security_labels])
          assert_equal true, item[:part2]
        end
      end

      test "FHIR: unreadable meta on a non-extracted entry marks the Bundle and every item Part 2" do
        observation = { "resourceType" => "Observation", "subject" => { "reference" => "Patient/123" }, "meta" => { "security" => [ nil ] } }
        result = import_bundle([ observation, resource("Condition") ])

        assert result.success?, result.errors.inspect
        assert_equal [], result.imported[:security_labels]
        assert_equal true, result.imported[:part2]
        assert_equal [], result.imported[:conditions].first[:security_labels]
        assert_equal true, result.imported[:conditions].first[:part2]
      end

      test "C-CDA: Part 2 label reaches the imported items via the real parser" do
        result = import_ccda(%(<confidentialityCode code="R" codeSystem="2.16.840.1.113883.5.25"/>))

        assert result.success?
        assert_equal [ { system: CONF, code: "R" } ], result.imported[:security_labels]
        condition = result.imported[:conditions].first
        assert_equal "E11.9", condition[:code]
        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(condition[:security_labels])
        assert_equal true, condition[:part2]
        assert_equal true, result.imported[:part2]
      end

      test "C-CDA: unreadable confidentialityCode does not reject the import; everything is marked Part 2" do
        result = import_ccda(%(<confidentialityCode nullFlavor="NI"/>))

        assert result.success?, "an unreadable security label must not reject the import: #{result.errors.inspect}"
        assert_equal [], result.imported[:security_labels]
        assert_equal true, result.imported[:part2]
        assert_equal [ { system: ACT, code: "42CFRPart2" } ], result.imported[:conditions].first[:security_labels]
        assert_equal true, result.imported[:conditions].first[:part2]
      end

      # Rule E: malformed C-CDA fails with a fixed message that echoes no document content.
      test "C-CDA: malformed XML or a wrong root fails with a fixed, content-free message" do
        unquoted = ccda_xml("").sub(%(code="42CFRPart2"), "code=42CFRPart2")
        wrong_root = ccda_xml("").gsub("ClinicalDocument", "SyntheticRoot")
        results = [ unquoted, wrong_root ].map { |xml| import_ccda(nil, xml: xml) }

        results.each do |result|
          refute result.success?, "malformed C-CDA must not be imported"
          assert_nil result.imported
          assert result.errors.any?(&:present?)
          refute result.errors.join(" ").match?(/42CFRPart2|SyntheticRoot|E11\.9|confidentialityCode/), "error must not echo document content"
        end
        assert_equal results.first.errors, results.last.errors, "message is fixed, not derived from the document"
      end

      test "imported is nil on an unrelated failure" do
        result = @service.import_from_fhir_bundle(patient_dfn: "123", clinician_duz: "301", json_string: "not-json")

        refute result.success?
        assert_respond_to result, :imported
        assert_nil result.imported
      end

      # Rule F: a DOCTYPE is malformed, with the same fixed message as other malformed documents.
      test "C-CDA: a document with a DOCTYPE fails like any malformed document" do
        hidden = %(<confidentialityCode code="R" codeSystem="2.16.840.1.113883.5.25"/>)
        entity = "<!DOCTYPE ClinicalDocument [<!ENTITY labels '#{hidden}'>]>\n" + ccda_xml("&labels;")
        external = %(<!DOCTYPE ClinicalDocument SYSTEM "synthetic.dtd">\n) + ccda_xml("")
        malformed = import_ccda(nil, xml: ccda_xml("").sub("</structuredBody>", ""))

        refute malformed.success?
        [ entity, external ].each do |xml|
          result = import_ccda(nil, xml: xml)

          refute result.success?, "a C-CDA with a DOCTYPE must not be imported"
          assert_equal malformed.errors, result.errors
          assert_nil result.imported
        end
      end

      # Rule G: a Part 2 Coding nested inside a label counts for the label's owner.
      test "FHIR: Part 2 Coding nested in a meta.security Coding or a securityLabel concept marks that item" do
        nested = [ { "url" => "http://example.test/synthetic-nested-label", "valueCoding" => PART2_CODING } ]
        result = import_bundle([
          resource("Condition", meta: { "security" => [ R_CODING.merge("extension" => nested) ] }),
          resource("MedicationRequest").merge("contained" => [
            { "resourceType" => "DocumentReference", "id" => "d1", "securityLabel" => [ { "coding" => [ R_CODING ], "extension" => nested } ] }
          ]),
          resource("AllergyIntolerance")
        ])

        assert result.success?, result.errors.inspect
        [ result.imported[:conditions].first, result.imported[:medications].first ].each do |item|
          assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(item[:security_labels])
          assert_equal true, item[:part2]
        end
        assert_equal false, result.imported[:allergies].first[:part2]
        assert_equal true, result.imported[:part2]
      end

      test "FHIR: Part 2 Coding nested in a Bundle meta.security Coding marks the Bundle and every item" do
        nested = [ { "url" => "http://example.test/synthetic-nested-label", "valueCoding" => PART2_CODING } ]
        result = import_bundle([ resource("Condition") ], meta: { "security" => [ R_CODING.merge("extension" => nested) ] })

        assert result.success?, result.errors.inspect
        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(result.imported[:security_labels])
        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(result.imported[:conditions].first[:security_labels])
        assert_equal true, result.imported[:conditions].first[:part2]
        assert_equal true, result.imported[:part2]
      end

      # Rule H: a Part 2 code as a primitive valueCode.
      test "FHIR: Part 2 valueCode on an extracted resource marks that item" do
        extension = [ { "url" => "http://example.test/synthetic-sensitivity", "valueCode" => "42CFRPart2" } ]
        result = import_bundle([ resource("Condition").merge("extension" => extension), resource("MedicationRequest") ])

        assert result.success?, result.errors.inspect
        assert_equal [ { code: "42CFRPart2" } ], result.imported[:conditions].first[:security_labels]
        assert_equal true, result.imported[:conditions].first[:part2]
        assert_equal false, result.imported[:medications].first[:part2]
        assert_equal true, result.imported[:part2]
      end

      # Rule I: a duplicate key could hide a label behind a later, empty value.
      test "FHIR: Bundle JSON with a duplicate object key is invalid JSON" do
        bundle = { "resourceType" => "Bundle", "entry" => [ { "resource" => resource("Condition", meta: { "security" => [ PART2_CODING ] }) } ] }
        json = bundle.to_json.sub(%("meta":), %("meta":{},"meta":))
        assert_equal 2, json.scan(%("meta":)).size

        result = @service.import_from_fhir_bundle(patient_dfn: "123", clinician_duz: "301", json_string: json)

        refute result.success?, "duplicate keys must be rejected, not resolved by last-wins"
        assert_includes result.errors, "Invalid JSON"
        assert_nil result.imported
      end

      # Rule K: invalid UTF-8 anywhere is invalid JSON, never an exception.
      {
        "a clinical code" => [ %("code":"E11.9"), "\"code\":\"E11\xF3\"".b ],
        "a security label display" => [ %("display":"restricted"), "\"display\":\"restricted\xFF\"".b ]
      }.each do |place, (valid, invalid)|
        [ Encoding::UTF_8, Encoding::BINARY ].each do |encoding|
          test "FHIR: invalid UTF-8 in #{place} (#{encoding} string) is Invalid JSON" do
            bundle = { "resourceType" => "Bundle", "entry" => [ { "resource" => resource("Condition", meta: { "security" => [ R_CODING, PART2_CODING ] }) } ] }
            json = bundle.to_json.b.sub(valid.b) { invalid }.force_encoding(encoding)
            refute json.dup.force_encoding(Encoding::UTF_8).valid_encoding?, "fixture must hold invalid UTF-8"

            result = assert_nothing_raised do
              @service.import_from_fhir_bundle(patient_dfn: "123", clinician_duz: "301", json_string: json)
            end

            refute result.success?, "invalid UTF-8 must not be imported"
            assert_equal [ "Invalid JSON" ], result.errors
            assert_nil result.imported
          end
        end
      end

      # Rule L: an undeclared namespace prefix is malformed, with the fixed message.
      test "C-CDA: an undeclared namespace prefix fails like any malformed document" do
        element = ccda_xml(%(<foo:confidentialityCode nullFlavor="NI"/>))
        attribute = ccda_xml("").sub(%( code="42CFRPart2"), %( foo:code="42CFRPart2"))
        malformed = import_ccda(nil, xml: ccda_xml("").sub("</structuredBody>", ""))

        refute malformed.success?
        [ element, attribute ].each do |xml|
          result = import_ccda(nil, xml: xml)

          refute result.success?, "a C-CDA with an unbound prefix must not be imported"
          assert_equal malformed.errors, result.errors
          assert_nil result.imported
        end
      end
    end
  end
end
