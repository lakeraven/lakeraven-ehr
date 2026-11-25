# frozen_string_literal: true

require "test_helper"

# lakeraven-ehr#908 (slice of #522): confidentialityCode / DS4P security
# labels must survive C-CDA ingest. Labels are a marker, never a block:
# an unreadable label marks its scope as suspected Part 2 (part2: true)
# without rejecting the document or inventing a value. Synthetic data only.
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
      def security_obs(code, oid: ACT_OID)
        <<~XML
          <entryRelationship typeCode="COMP"><observation classCode="OBS" moodCode="EVN">
            <code code="SECCLASSOBS" codeSystem="2.16.840.1.113883.1.11.20457"/>
            <value xsi:type="CE" code="#{code}"#{%( codeSystem="#{oid}") if oid}/>
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
               allergies_header: "", conditions_header: "", medications_header: "", extra: "")
        <<~XML
          <ClinicalDocument xmlns="urn:hl7-org:v3" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            #{header}
            <component><structuredBody>
              #{section(ALLERGIES, allergies, allergies_header)}
              #{section(PROBLEMS, conditions, conditions_header)}
              #{section(MEDS, medications, medications_header)}
              #{extra}
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

        assert_equal false, result[:part2]
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
        assert_equal false, result[:part2]
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
        assert_equal true, result[:part2], "top-level part2 is true when any label anywhere is Part 2"
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

      # --- Rule A: unreadable label is a marker (suspected Part 2), never a block ---

      test "unreadable document confidentialityCode (nullFlavor only) marks everything Part 2 without inventing a label" do
        result = parse(header: %(<confidentialityCode nullFlavor="NI"/>))

        assert_equal [], result[:security_labels]
        assert_equal true, result[:part2]
        assert_equal 3, items(result).size
        items(result).each do |item|
          assert_equal [], item[:security_labels]
          assert_equal true, item[:part2]
        end
      end

      test "blank confidentialityCode code inside an entry marks only that entry Part 2" do
        result = parse(header: conf("N"), allergies: allergy(conf("")) + allergy)

        assert_equal [ { system: CONF, code: "N" } ], result[:allergies][0][:security_labels]
        assert_equal true, result[:allergies][0][:part2]
        assert_equal false, result[:allergies][1][:part2]
        assert_equal false, result[:conditions].first[:part2]
        assert_equal true, result[:part2]
      end

      test "unreadable section confidentialityCode marks that section's entries Part 2" do
        result = parse(header: conf("N"), medications_header: %(<confidentialityCode nullFlavor="UNK"/>))

        assert_equal [ { system: CONF, code: "N" } ], result[:medications].first[:security_labels]
        assert_equal true, result[:medications].first[:part2]
        assert_equal false, result[:allergies].first[:part2]
        assert_equal true, result[:part2]
      end

      test "label with no codeSystem is unreadable: entry is Part 2 and no label is invented" do
        result = parse(conditions: condition(security_obs("42CFRPart2", oid: nil)),
                       medications: medication(%(<confidentialityCode code="R"/>)))

        [ result[:conditions].first, result[:medications].first ].each do |item|
          assert_equal [], item[:security_labels]
          assert_equal true, item[:part2]
        end
        assert_equal false, result[:allergies].first[:part2]
      end

      # --- Rule C: no label is lost by position ---

      test "label-only sibling entry in an imported section labels that section's entries" do
        label_only = %(<entry><act classCode="ACT" moodCode="EVN"><code code="42CFRPart2" codeSystem="#{ACT_OID}"/></act></entry>)
        result = parse(header: conf("N"), conditions: condition + label_only)
        clinical = result[:conditions].select { |c| c[:code] == "E11.9" }

        assert_equal 1, clinical.size
        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "N" ] ], pairs(clinical.first[:security_labels])
        assert_equal true, clinical.first[:part2]
        assert_equal false, result[:allergies].first[:part2]
        assert_equal [ [ CONF, "N" ] ], pairs(result[:security_labels])
        assert_equal true, result[:part2]
      end

      test "labels in a non-imported section (header and entries) belong to the document" do
        # DS4P-style Privacy Markings section: not one of the three imported sections.
        privacy = section("2.16.840.1.113883.3.3251.1.5", "<entry><act classCode=\"ACT\" moodCode=\"EVN\">#{security_obs('42CFRPart2')}</act></entry>", conf("R"))
        result = parse(header: conf("N"), extra: privacy)
        expected = [ [ ACT, "42CFRPart2" ], [ CONF, "N" ], [ CONF, "R" ] ]

        assert_equal expected, pairs(result[:security_labels])
        assert_equal true, result[:part2]
        assert_equal 3, items(result).size
        items(result).each do |item|
          assert_equal expected, pairs(item[:security_labels])
          assert_equal true, item[:part2]
        end
      end

      # --- Rule D: label recognition ---

      test "v3-Confidentiality value outside a confidentialityCode element is a label" do
        result = parse(header: conf("N"), allergies: allergy(security_obs("R", oid: CONF_OID)))

        assert_equal [ [ CONF, "N" ], [ CONF, "R" ] ], pairs(result[:allergies].first[:security_labels])
        assert_equal [ [ CONF, "N" ] ], pairs(result[:conditions].first[:security_labels])
      end

      test "Part 2 code under a non-ActCode (value set) OID is a label mapped to urn:oid" do
        result = parse(conditions: condition(security_obs("SUD", oid: "2.16.840.1.113883.3.9999.2")))

        assert_equal [ { system: "urn:oid:2.16.840.1.113883.3.9999.2", code: "SUD" } ], result[:conditions].first[:security_labels]
        assert_equal true, result[:conditions].first[:part2]
      end

      test "codeSystem is compared ignoring a urn:oid: prefix and surrounding space/format characters" do
        result = parse(medications: medication(security_obs("&#x200B;42CFRPart2 ", oid: " urn:oid:#{ACT_OID}&#x200B;")))

        assert_equal [ { system: ACT, code: "​42CFRPart2 " } ], result[:medications].first[:security_labels]
        assert_equal true, result[:medications].first[:part2]
      end

      # --- Rule E: malformed C-CDA ---

      test "XML that is not well-formed raises" do
        # Unquoted attribute: a lenient parser would drop the Part 2 code silently.
        unquoted = ccda(conditions: condition(security_obs("42CFRPart2"))).sub(%(code="42CFRPart2"), "code=42CFRPart2")
        unclosed = ccda(header: conf("N")).sub("</structuredBody>", "")

        assert_raises(StandardError) { CcdaParser.parse(unquoted) }
        assert_raises(StandardError) { CcdaParser.parse(unclosed) }
      end

      test "root that is not ClinicalDocument in the HL7 v3 namespace raises" do
        assert_raises(StandardError) { CcdaParser.parse(ccda.gsub("ClinicalDocument", "Document")) }
        assert_raises(StandardError) { CcdaParser.parse(ccda.sub(%( xmlns="urn:hl7-org:v3"), "")) }
      end

      # --- Rule F: a DOCTYPE is malformed (entities can hide labels) ---

      test "DOCTYPE with an internal entity carrying labels raises" do
        hidden = %(<confidentialityCode code="R" codeSystem="#{CONF_OID}"/>) +
          %(<documentationOf><serviceEvent classCode="ACT"><code code="42CFRPart2" codeSystem="#{ACT_OID}"/></serviceEvent></documentationOf>)
        xml = "<!DOCTYPE ClinicalDocument [<!ENTITY labels '#{hidden}'>]>\n" + ccda(header: "&labels;")

        assert_raises(StandardError) { CcdaParser.parse(xml) }
      end

      test "DOCTYPE with an external SYSTEM id raises" do
        xml = %(<!DOCTYPE ClinicalDocument SYSTEM "synthetic.dtd">\n) + ccda(header: conf("N"))

        assert_raises(StandardError) { CcdaParser.parse(xml) }
      end

      # --- Rule J: confidentialityCode in any namespace is a label ---

      test "confidentialityCode outside the HL7 v3 namespace still marks its entry" do
        result = parse(header: conf("N"), allergies: allergy(%(<confidentialityCode xmlns="" nullFlavor="NI"/>)) + allergy)

        assert_equal [ { system: CONF, code: "N" } ], result[:allergies][0][:security_labels]
        assert_equal true, result[:allergies][0][:part2]
        assert_equal false, result[:allergies][1][:part2]
        assert_equal true, result[:part2]
      end

      # --- Rule L: an undeclared namespace prefix is malformed ---

      test "undeclared prefix on a label element or attribute raises" do
        element = ccda(header: conf("N"), allergies: allergy(%(<foo:confidentialityCode nullFlavor="NI"/>)))
        attribute = ccda(header: conf("N"), conditions: condition(security_obs("42CFRPart2")).sub(%( code="42CFRPart2"), %( foo:code="42CFRPart2")))
        assert_includes attribute, %(foo:code="42CFRPart2")

        assert_raises(StandardError) { CcdaParser.parse(element) }
        assert_raises(StandardError) { CcdaParser.parse(attribute) }
      end

      # --- Rule M: urn:oid: prefix is case-insensitive ---

      test "codeSystem urn:oid: prefix is stripped case-insensitively" do
        result = parse(header: conf("N"), allergies: allergy(security_obs("R", oid: "URN:OID:#{CONF_OID}")),
                       medications: medication(security_obs("42CFRPart2", oid: "Urn:Oid:#{ACT_OID}")))

        assert_equal [ [ CONF, "N" ], [ CONF, "R" ] ], pairs(result[:allergies].first[:security_labels])
        assert_equal [ [ ACT, "42CFRPart2" ], [ CONF, "N" ] ], pairs(result[:medications].first[:security_labels])
        assert_equal [ [ CONF, "N" ] ], pairs(result[:conditions].first[:security_labels])
      end
    end
  end
end
