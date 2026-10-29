# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/ccda_model_fixtures"

module Lakeraven
  module EHR
    class CcdaGeneratorTest < ActiveSupport::TestCase
      include CcdaModelFixtures

      HL7_NS = { "xmlns" => "urn:hl7-org:v3" }.freeze

      CLINICAL_SECTION_TEMPLATES = {
        "2.16.840.1.113883.10.20.22.2.6.1" => "48765-2",
        "2.16.840.1.113883.10.20.22.2.5.1" => "11450-4",
        "2.16.840.1.113883.10.20.22.2.1.1" => "10160-0",
        "2.16.840.1.113883.10.20.22.2.4.1" => "8716-3",
        "2.16.840.1.113883.10.20.22.2.22.1" => "46240-8"
      }.freeze

      setup do
        @patient = synthetic_patient
        @allergies = synthetic_allergies
        @conditions = synthetic_conditions
        @medications = synthetic_medications
        @vitals = synthetic_vitals
        @encounters = synthetic_encounters
        @author = synthetic_author
      end

      # =============================================================================
      # MODEL INPUT CONTRACT (#233) — hash fallback removed
      # =============================================================================

      test "rejects hash patient with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: { dfn: "900001", name: { given: "ONE", family: "TEST" } },
            allergies: [],
            conditions: [],
            medications: []
          )
        end
        assert_includes error.message, "patient"
        refute_includes error.message, "900001"
        refute_includes error.message, "ONE"
      end

      test "rejects nil patient with ArgumentError before XML" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: nil,
            allergies: [],
            conditions: [],
            medications: []
          )
        end
        assert_includes error.message, "patient"
      end

      test "rejects OpenStruct patient with ArgumentError before XML" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: OpenStruct.new(dfn: SYNTHETIC_DFN, name: "TEST,ONE"),
            allergies: [],
            conditions: [],
            medications: []
          )
        end
        assert_includes error.message, "patient"
        refute_includes error.message, SYNTHETIC_DFN.to_s
      end

      test "rejects non-Patient object as patient with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @allergies.first,
            allergies: [],
            conditions: [],
            medications: []
          )
        end
        assert_includes error.message, "patient"
        refute_includes error.message, "7980"
      end

      test "rejects hash allergy row with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: [ { code: "7980", display: "Penicillin" } ],
            conditions: @conditions,
            medications: @medications
          )
        end
        assert_includes error.message, "allergies"
        refute_includes error.message, "7980"
        refute_includes error.message, "Penicillin"
      end

      test "rejects OpenStruct allergy row with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: [ OpenStruct.new(allergen_code: "7980", allergen: "Penicillin") ],
            conditions: @conditions,
            medications: @medications
          )
        end
        assert_includes error.message, "allergies"
        refute_includes error.message, "7980"
      end

      test "rejects Condition instance in allergies list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: [ @conditions.first ],
            conditions: @conditions,
            medications: @medications
          )
        end
        assert_includes error.message, "allergies"
        refute_includes error.message, "E11.9"
      end

      test "rejects non-Array allergies list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: "not-an-array",
            conditions: @conditions,
            medications: @medications
          )
        end
        assert_includes error.message, "allergies"
        refute_includes error.message, "not-an-array"
      end

      test "rejects hash condition row with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: @allergies,
            conditions: [ { code: "E11.9", display: "Type 2 diabetes mellitus" } ],
            medications: @medications
          )
        end
        assert_includes error.message, "conditions"
        refute_includes error.message, "E11.9"
      end

      test "rejects AllergyIntolerance instance in conditions list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: @allergies,
            conditions: [ @allergies.first ],
            medications: @medications
          )
        end
        assert_includes error.message, "conditions"
        refute_includes error.message, "7980"
      end

      test "rejects non-Array conditions list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: @allergies,
            conditions: Condition.new(code: "I10", display: "Hypertension"),
            medications: @medications
          )
        end
        assert_includes error.message, "conditions"
      end

      test "rejects hash medication row with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: @allergies,
            conditions: @conditions,
            medications: [ { code: "311364", display: "Lisinopril 10 MG Oral Tablet" } ]
          )
        end
        assert_includes error.message, "medications"
        refute_includes error.message, "311364"
      end

      test "rejects non-Array medications list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: @allergies,
            conditions: @conditions,
            medications: @medications.first
          )
        end
        assert_includes error.message, "medications"
      end

      test "rejects hash vital row with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            vitals: [ { code: "8480-6", display: "Systolic BP", value: "120", units: "mm[Hg]", date: "2026-03-01" } ]
          )
        end
        assert_includes error.message, "vitals"
        refute_includes error.message, "8480-6"
      end

      test "rejects Encounter instance in vitals list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            vitals: [ @encounters.first ]
          )
        end
        assert_includes error.message, "vitals"
        refute_includes error.message, "99213"
      end

      test "rejects non-Array vitals list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            vitals: @vitals.first
          )
        end
        assert_includes error.message, "vitals"
      end

      test "rejects hash encounter row with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            encounters: [ { date: "2026-03-01", type_code: "99213", type_display: "Office visit", performer: "Dr. Smith" } ]
          )
        end
        assert_includes error.message, "encounters"
        refute_includes error.message, "99213"
        refute_includes error.message, "Dr. Smith"
      end

      test "rejects Observation instance in encounters list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            encounters: [ @vitals.first ]
          )
        end
        assert_includes error.message, "encounters"
        refute_includes error.message, "8480-6"
      end

      test "rejects non-Array encounters list with ArgumentError" do
        error = assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            encounters: @encounters.first
          )
        end
        assert_includes error.message, "encounters"
      end

      test "nil clinical lists are treated as empty" do
        xml = CcdaGenerator.generate(
          patient: @patient,
          allergies: nil,
          conditions: nil,
          medications: nil,
          vitals: nil,
          encounters: nil,
          author: @author
        )
        doc = Nokogiri::XML(xml)

        assert doc.errors.empty?, "Expected valid XML with nil lists coerced to empty"
      end

      # =============================================================================
      # DOCUMENT STRUCTURE
      # =============================================================================

      test "generates valid XML" do
        xml = generate_ccda
        doc = Nokogiri::XML(xml) { |config| config.strict }

        assert doc.errors.empty?, "Expected valid XML, got errors: #{doc.errors.map(&:message)}"
      end

      test "includes CCD template ID" do
        doc = parse_ccda

        template_ids = doc.xpath("//xmlns:templateId/@root", "xmlns" => "urn:hl7-org:v3").map(&:value)
        assert_includes template_ids, "2.16.840.1.113883.10.20.22.1.2"
      end

      test "includes document type code for CCD" do
        doc = parse_ccda

        code = doc.at_xpath("//xmlns:code/@code", "xmlns" => "urn:hl7-org:v3")
        assert_equal "34133-9", code&.value
      end

      test "includes effective time" do
        doc = parse_ccda

        time = doc.at_xpath("//xmlns:effectiveTime/@value", "xmlns" => "urn:hl7-org:v3")
        assert time&.value.present?, "Expected effectiveTime"
      end

      # =============================================================================
      # PATIENT DEMOGRAPHICS (Patient model attributes)
      # =============================================================================

      test "includes patient name from Patient name FAMILY,GIVEN" do
        doc = parse_ccda

        given = doc.at_xpath("//xmlns:patient/xmlns:name/xmlns:given", "xmlns" => "urn:hl7-org:v3")
        family = doc.at_xpath("//xmlns:patient/xmlns:name/xmlns:family", "xmlns" => "urn:hl7-org:v3")
        assert_equal "PATIENT ONE", given&.text
        assert_equal "TEST", family&.text
      end

      test "includes patient DFN as ID" do
        doc = parse_ccda

        id = doc.at_xpath("//xmlns:patientRole/xmlns:id/@extension", "xmlns" => "urn:hl7-org:v3")
        assert_equal "900001", id&.value
      end

      test "includes patient birth time" do
        doc = parse_ccda

        dob = doc.at_xpath("//xmlns:patient/xmlns:birthTime/@value", HL7_NS)
        assert_equal "19750615", dob&.value
      end

      test "includes patient gender" do
        doc = parse_ccda

        gender = doc.at_xpath("//xmlns:patient/xmlns:administrativeGenderCode/@code", "xmlns" => "urn:hl7-org:v3")
        assert_equal "M", gender&.value
      end

      test "includes patient address from flat address attributes" do
        doc = parse_ccda
        ns = HL7_NS

        street = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:streetAddressLine", ns)
        city = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:city", ns)
        state = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:state", ns)
        zip = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:postalCode", ns)

        assert_equal "123 Main St", street&.text
        assert_equal "Anchorage", city&.text
        assert_equal "AK", state&.text
        assert_equal "99501", zip&.text
      end

      test "omits patient addr when all address fields are blank" do
        patient = synthetic_patient(
          address_line1: nil,
          city: nil,
          state: nil,
          zip_code: nil
        )
        xml = CcdaGenerator.generate(patient:, allergies: [], conditions: [], medications: [], author: @author)
        doc = Nokogiri::XML(xml)

        refute doc.at_xpath("//xmlns:patientRole/xmlns:addr", HL7_NS),
          "Expected no addr when street, city, state, and zip are all blank"
      end

      test "patient addr includes only present address parts" do
        patient = synthetic_patient(
          address_line1: "456 Oak Ave",
          city: nil,
          state: "AK",
          zip_code: nil
        )
        xml = CcdaGenerator.generate(patient:, allergies: [], conditions: [], medications: [], author: @author)
        doc = Nokogiri::XML(xml)
        ns = HL7_NS

        addr = doc.at_xpath("//xmlns:patientRole/xmlns:addr", ns)
        assert addr.present?, "Expected addr when at least one field is present"

        assert_equal "456 Oak Ave", addr.at_xpath("./xmlns:streetAddressLine", ns)&.text
        refute addr.at_xpath("./xmlns:city", ns)
        assert_equal "AK", addr.at_xpath("./xmlns:state", ns)&.text
        refute addr.at_xpath("./xmlns:postalCode", ns)
      end

      test "patient birthTime uses HL7 date form YYYYMMDD for Date dob" do
        doc = parse_ccda

        dob = doc.at_xpath("//xmlns:patient/xmlns:birthTime/@value", HL7_NS)
        assert_equal "19750615", dob&.value
        assert_match(/\A\d{8}\z/, dob&.value)
        refute_match(/\+/, dob&.value)
      end

      # =============================================================================
      # SECTION ELEMENT ORDER (#233 round-1) — templateId, code, title, then entries
      # =============================================================================

      test "each clinical section emits templateId code title before entries" do
        doc = parse_ccda

        CLINICAL_SECTION_TEMPLATES.each do |template_root, loinc_code|
          section = clinical_section(doc, template_root)
          assert section.present?, "Expected section with template #{template_root}"

          assert_section_prefix_order(section)
          section_code = section.at_xpath("./xmlns:code", HL7_NS)
          assert_equal loinc_code, section_code&.[]("code"), "section #{template_root} LOINC"
        end
      end

      test "encounters section LOINC 46240-8 precedes title even with no encounter entries" do
        xml = CcdaGenerator.generate(
          patient: @patient,
          allergies: [],
          conditions: [],
          medications: [],
          vitals: [],
          encounters: [],
          author: @author
        )
        doc = Nokogiri::XML(xml)
        section = clinical_section(doc, "2.16.840.1.113883.10.20.22.2.22.1")
        assert section.present?

        assert_section_prefix_order(section)
        section_code = section.at_xpath("./xmlns:code", HL7_NS)
        assert_equal "46240-8", section_code&.[]("code")

        entries = section.xpath("./xmlns:entry", HL7_NS)
        assert_empty entries
      end

      # =============================================================================
      # CLINICAL SECTIONS
      # =============================================================================

      test "includes allergies section with template ID" do
        doc = parse_ccda

        allergy_template = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.6.1']]",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert allergy_template.present?, "Expected allergies section"
      end

      test "allergies section contains coded entries" do
        doc = parse_ccda

        entries = doc.xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.6.1']]//xmlns:entry",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert_equal 2, entries.length
      end

      test "includes problems section with template ID" do
        doc = parse_ccda

        problem_template = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.5.1']]",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert problem_template.present?, "Expected problems section"
      end

      test "problems section contains coded entries" do
        doc = parse_ccda

        entries = doc.xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.5.1']]//xmlns:entry",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert_equal 2, entries.length
      end

      test "includes medications section with template ID" do
        doc = parse_ccda

        med_template = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.1.1']]",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert med_template.present?, "Expected medications section"
      end

      test "medications section contains coded entries" do
        doc = parse_ccda

        entries = doc.xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.1.1']]//xmlns:entry",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert_equal 2, entries.length
      end

      test "includes vital signs section" do
        doc = parse_ccda

        vitals_template = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.4.1']]",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert vitals_template.present?, "Expected vital signs section"
      end

      test "vital observation uses Observation effective_datetime and unit" do
        doc = parse_ccda
        ns = { "xmlns" => "urn:hl7-org:v3" }

        effective = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.4.1']]//xmlns:effectiveTime/@value",
          ns
        )
        value = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.4.1']]//xmlns:value/@value",
          ns
        )
        unit = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.4.1']]//xmlns:value/@unit",
          ns
        )

        assert_equal "20260301120000+0000", effective&.value
        assert_equal "120", value&.value
        assert_equal "mm[Hg]", unit&.value
      end

      test "includes encounters section" do
        doc = parse_ccda

        encounters_template = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert encounters_template.present?, "Expected encounters section"
      end

      # Previously used //code in the section (matched LOINC 46240-8 once section
      # code precedes title) and asserted performer/text held a display name.
      test "encounter entry uses type_code period_start and practitioner id on performer" do
        doc = parse_ccda
        ns = HL7_NS
        section_xpath = "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]"

        type_code = doc.at_xpath(
          "#{section_xpath}//xmlns:entry//xmlns:encounter/xmlns:code/@code",
          ns
        )
        effective = doc.at_xpath(
          "#{section_xpath}//xmlns:entry//xmlns:encounter/xmlns:effectiveTime/@value",
          ns
        )
        performer_extension = doc.at_xpath(
          "#{section_xpath}//xmlns:entry//xmlns:encounter//xmlns:performer/" \
          "xmlns:assignedEntity/xmlns:id/@extension",
          ns
        )
        performer_root = doc.at_xpath(
          "#{section_xpath}//xmlns:entry//xmlns:encounter//xmlns:performer/" \
          "xmlns:assignedEntity/xmlns:id/@root",
          ns
        )

        assert_equal "99213", type_code&.value
        assert_equal "20260301090000+0000", effective&.value
        assert_equal SYNTHETIC_PRACTITIONER_ID, performer_extension&.value
        assert_equal "2.16.840.1.113883.19.5", performer_root&.value

        refute doc.at_xpath("#{section_xpath}//xmlns:performer//xmlns:name", ns),
          "practitioner_identifier must not be written into performer name"
        refute doc.at_xpath("#{section_xpath}//xmlns:performer//xmlns:text", ns),
          "no text element inside performer name"
      end

      test "omits encounter performer when practitioner_identifier is blank" do
        encounter = Encounter.new(
          patient_dfn: SYNTHETIC_DFN,
          status: "finished",
          class_code: "AMB",
          type_code: "99213",
          type_display: "Office visit",
          period_start: Time.utc(2026, 3, 1, 9, 0, 0),
          practitioner_identifier: ""
        )
        xml = CcdaGenerator.generate(
          patient: @patient,
          encounters: [ encounter ],
          allergies: [],
          conditions: [],
          medications: [],
          author: @author
        )
        doc = Nokogiri::XML(xml)
        ns = HL7_NS

        refute doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]" \
          "//xmlns:entry//xmlns:encounter/xmlns:performer",
          ns
        )
      end

      # =============================================================================
      # AUTHOR AND CUSTODIAN (author remains a hash)
      # =============================================================================

      test "includes author section" do
        doc = parse_ccda

        author = doc.at_xpath("//xmlns:author", "xmlns" => "urn:hl7-org:v3")
        assert author.present?, "Expected author"
      end

      test "includes custodian section" do
        doc = parse_ccda

        custodian = doc.at_xpath("//xmlns:custodian", "xmlns" => "urn:hl7-org:v3")
        assert custodian.present?, "Expected custodian"
      end

      # =============================================================================
      # ROUND-TRIP — generated C-CDA can be parsed
      # =============================================================================

      test "generated document can be parsed by CcdaParser" do
        xml = generate_ccda
        parsed = CcdaParser.parse(xml)

        assert_equal 2, parsed[:allergies].length
        assert_equal 2, parsed[:conditions].length
        assert_equal 2, parsed[:medications].length
      end

      test "parsed allergy codes match input allergen_code" do
        xml = generate_ccda
        parsed = CcdaParser.parse(xml)

        codes = parsed[:allergies].map { |a| a[:allergen_code] }
        assert_includes codes, "7980"
        assert_includes codes, "36567"
      end

      # =============================================================================
      # EDGE CASES
      # =============================================================================

      test "generates document with no allergies" do
        xml = CcdaGenerator.generate(
          patient: @patient,
          allergies: [],
          conditions: @conditions,
          medications: @medications,
          author: @author
        )
        doc = Nokogiri::XML(xml)

        assert doc.errors.empty?, "Expected valid XML with empty allergies"
      end

      test "generates document with empty clinical data" do
        xml = CcdaGenerator.generate(
          patient: @patient,
          allergies: [],
          conditions: [],
          medications: [],
          author: @author
        )
        doc = Nokogiri::XML(xml)

        assert doc.errors.empty?, "Expected valid XML with no clinical data"
      end

      # =============================================================================
      # PERFORMANCE
      # =============================================================================

      test "generation completes within 5 seconds" do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        generate_ccda
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

        assert elapsed < 5.0, "C-CDA generation took #{elapsed}s, expected < 5s"
      end

      private

      def generate_ccda
        CcdaGenerator.generate(
          patient: @patient,
          allergies: @allergies,
          conditions: @conditions,
          medications: @medications,
          vitals: @vitals,
          encounters: @encounters,
          author: @author
        )
      end

      def parse_ccda
        xml = generate_ccda
        Nokogiri::XML(xml)
      end

      def clinical_section(doc, template_root)
        doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='#{template_root}']]",
          HL7_NS
        )
      end

      def assert_section_prefix_order(section)
        names = section.element_children.map(&:name)
        template_idx = names.index("templateId")
        code_idx = names.index("code")
        title_idx = names.index("title")

        assert template_idx, "expected templateId child on section, got #{names.inspect}"
        assert code_idx, "expected code child on section, got #{names.inspect}"
        assert title_idx, "expected title child on section, got #{names.inspect}"
        assert template_idx < code_idx, "templateId must precede code; got #{names.inspect}"
        assert code_idx < title_idx, "code must precede title; got #{names.inspect}"

        names[0..title_idx].each do |name|
          refute_equal "entry", name, "entry must follow title; got #{names.inspect}"
        end
      end
    end
  end
end
