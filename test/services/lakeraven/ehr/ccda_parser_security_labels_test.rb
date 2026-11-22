# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#908 (slice of #522): confidentialityCode / DS4P security
# labels must survive C-CDA ingest. Labels are a marker, never a block;
# an unreadable label fails closed. Synthetic data only.
module Lakeraven
  module EHR
    class CcdaParserSecurityLabelsTest < ActiveSupport::TestCase
      CONF_OID = "2.16.840.1.113883.5.25"
      ACT_OID  = "2.16.840.1.113883.5.4"
      CONF = "http://terminology.hl7.org/CodeSystem/v3-Confidentiality"
      ACT  = "http://terminology.hl7.org/CodeSystem/v3-ActCode"
      ALLERGIES = "2.16.840.1.113883.10.20.22.2.6.1"
      PROBLEMS  = "2.16.840.1.113883.10.20.22.2.5.1"
      MEDS      = "2.16.840.1.113883.10.20.22.2.1.1"

      def conf(code, oid: CONF_OID, display: nil)
        %(<confidentialityCode code="#{code}" codeSystem="#{oid}"#{%( displayName="#{display}") if display}/>)
      end

      # DS4P-style security observation carried in an entryRelationship.
      def security_obs(code)
        <<~XML
          <entryRelationship typeCode="COMP"><observation classCode="OBS" moodCode="EVN">
            <code code="SECCLASSOBS" codeSystem="2.16.840.1.113883.1.11.20457"/>
            <value xsi:type="CE" code="#{code}" codeSystem="#{ACT_OID}"/>
          </observation></entryRelationship>
        XML
      end

      def allergy(extra = "")
        <<~XML
          <entry><act classCode="ACT" moodCode="EVN"><entryRelationship typeCode="SUBJ">
            <observation classCode="OBS" moodCode="EVN"><participant typeCode="CSM"><participantRole><playingEntity>
              <code code="7980" displayName="Penicillin"/>
            </playingEntity></participantRole></participant></observation>
          </entryRelationship>#{extra}</act></entry>
        XML
      end

      def condition(extra = "")
        <<~XML
          <entry><act classCode="ACT" moodCode="EVN"><entryRelationship typeCode="SUBJ">
            <observation classCode="OBS" moodCode="EVN"><value xsi:type="CD" code="E11.9" displayName="Test condition"/></observation>
          </entryRelationship>#{extra}</act></entry>
        XML
      end

      def medication(extra = "")
        <<~XML
          <entry><substanceAdministration classCode="SBADM" moodCode="EVN"><consumable><manufacturedProduct><manufacturedMaterial>
            <code code="197361" displayName="Test medication"/>
          </manufacturedMaterial></manufacturedProduct></consumable>#{extra}</substanceAdministration></entry>
        XML
      end

      def section(template, body, header = "")
        %(<component><section><templateId root="#{template}"/>#{header}#{body}</section></component>)
      end

      def ccda(header: "", allergies: allergy, conditions: condition, medications: medication,
               allergies_header: "", conditions_header: "", medications_header: "")
        <<~XML
          <ClinicalDocument xmlns="urn:hl7-org:v3" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            #{header}
            <component><structuredBody>
              #{section(ALLERGIES, allergies, allergies_header)}
              #{section(PROBLEMS, conditions, conditions_header)}
              #{section(MEDS, medications, medications_header)}
            </structuredBody></component>
          </ClinicalDocument>
        XML
      end

      def parse(**opts) = CcdaParser.parse(ccda(**opts))
      def items(result) = result.values_at(:allergies, :conditions, :medications).flatten
      def pairs(labels) = labels.map { |l| [ l[:system], l[:code] ] }.sort

      test "document confidentialityCode is kept on the document and on every entry" do
        result = parse(header: conf("R"))

        assert_equal [ { system: CONF, code: "R" } ], result[:security_labels]
        assert_equal 3, items(result).size
        items(result).each do |item|
          assert_equal [ { system: CONF, code: "R" } ], item[:security_labels]
          assert_equal false, item[:part2]
        end
      end

      test "displayName is carried as display only when the source has one" do
        result = parse(header: conf("R", display: "Restricted"))

        assert_equal [ { system: CONF, code: "R", display: "Restricted" } ], result[:security_labels]
      end

      test "normal (N) document is labelled N and not Part 2; existing fields unchanged" do
        result = parse(header: conf("N"))

        items(result).each do |item|
          assert_equal [ { system: CONF, code: "N" } ], item[:security_labels]
          assert_equal false, item[:part2]
        end
        assert_equal "7980", result[:allergies].first[:allergen_code]
        assert_equal "Penicillin", result[:allergies].first[:allergen_display]
        assert_equal "E11.9", result[:conditions].first[:code]
        assert_equal "Test condition", result[:conditions].first[:display]
        assert_equal "197361", result[:medications].first[:code]
        assert_equal "Test medication", result[:medications].first[:display]
      end

      test "document with no confidentialityCode yields empty labels, never nil" do
        result = parse

        assert_equal [], result[:security_labels]
        items(result).each do |item|
          assert_equal [], item[:security_labels]
          assert_equal false, item[:part2]
        end
      end

      test "section confidentialityCode labels only that section's entries, plus document labels" do
        result = parse(header: conf("N"), conditions_header: conf("R"))

        assert_equal [ [ CONF, "N" ], [ CONF, "R" ] ], pairs(result[:conditions].first[:security_labels])
        assert_equal [ [ CONF, "N" ] ], pairs(result[:allergies].first[:security_labels])
        assert_equal [ [ CONF, "N" ] ], pairs(result[:medications].first[:security_labels])
        assert_equal [ [ CONF, "N" ] ], pairs(result[:security_labels])
      end

      test "confidentialityCode nested inside an entry labels that entry only" do
        nested = %(<entryRelationship typeCode="COMP"><act classCode="ACT" moodCode="EVN">#{conf('V')}</act></entryRelationship>)
        result = parse(header: conf("N"), allergies: allergy(nested) + allergy)

        assert_equal [ [ CONF, "N" ], [ CONF, "V" ] ], pairs(result[:allergies][0][:security_labels])
        assert_equal [ [ CONF, "N" ] ], pairs(result[:allergies][1][:security_labels])
      end

      test "labels are de-duplicated on system and code" do
        result = parse(header: conf("R"), conditions_header: conf("R"), conditions: condition(conf("R")))

        assert_equal [ { system: CONF, code: "R" } ], result[:conditions].first[:security_labels]
      end

      test "unknown code system OID maps to urn:oid" do
        result = parse(medications_header: conf("TESTLABEL", oid: "2.16.840.1.113883.3.9999.1"))

        assert_equal [ { system: "urn:oid:2.16.840.1.113883.3.9999.1", code: "TESTLABEL" } ],
          result[:medications].first[:security_labels]
      end

      test "DS4P Part 2 security observation in an entry marks that entry Part 2" do
        result = parse(header: conf("N"), conditions: condition(security_obs("42CFRPart2")) + condition)
        labelled, plain = result[:conditions]

        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "N" ] ], pairs(labelled[:security_labels])
        assert_equal true, labelled[:part2]
        assert_equal "E11.9", labelled[:code]
        assert_equal false, plain[:part2]
        assert_equal false, result[:allergies].first[:part2]
        assert_equal [ [ CONF, "N" ] ], pairs(result[:security_labels])
      end

      test "Part 2 code matching is case-insensitive and the code is kept verbatim" do
        result = parse(medications: medication(security_obs("eth")))

        assert_equal [ { system: ACT, code: "eth" } ], result[:medications].first[:security_labels]
        assert_equal true, result[:medications].first[:part2]
      end

      test "document-level Part 2 ActCode outside sections labels the document and every entry" do
        header = conf("R") + %(<documentationOf><serviceEvent classCode="ACT"><code code="42CFRPart2" codeSystem="#{ACT_OID}"/></serviceEvent></documentationOf>)
        result = parse(header: header)

        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(result[:security_labels])
        items(result).each do |item|
          assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "R" ] ], pairs(item[:security_labels])
          assert_equal true, item[:part2]
        end
      end

      test "fail closed: confidentialityCode with only a nullFlavor raises" do
        assert_raises(StandardError) { parse(header: %(<confidentialityCode nullFlavor="NI"/>)) }
      end

      test "fail closed: blank confidentialityCode code inside an entry raises" do
        assert_raises(StandardError) { parse(header: conf("N"), allergies: allergy(conf(""))) }
      end
    end
  end
end
