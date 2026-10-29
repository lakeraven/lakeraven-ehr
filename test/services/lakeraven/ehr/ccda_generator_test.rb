# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/ccda_model_fixtures"

module Lakeraven
  module EHR
    class CcdaGeneratorTest < ActiveSupport::TestCase
      include CcdaModelFixtures

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
        assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: { dfn: "900001", name: { given: "ONE", family: "TEST" } },
            allergies: [],
            conditions: [],
            medications: []
          )
        end
      end

      test "rejects hash allergy row with ArgumentError" do
        assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: [ { code: "7980", display: "Penicillin" } ],
            conditions: @conditions,
            medications: @medications
          )
        end
      end

      test "rejects hash condition row with ArgumentError" do
        assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: @allergies,
            conditions: [ { code: "E11.9", display: "Type 2 diabetes mellitus" } ],
            medications: @medications
          )
        end
      end

      test "rejects hash medication row with ArgumentError" do
        assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            allergies: @allergies,
            conditions: @conditions,
            medications: [ { code: "311364", display: "Lisinopril 10 MG Oral Tablet" } ]
          )
        end
      end

      test "rejects hash vital row with ArgumentError" do
        assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            vitals: [ { code: "8480-6", display: "Systolic BP", value: "120", units: "mm[Hg]", date: "2026-03-01" } ]
          )
        end
      end

      test "rejects hash encounter row with ArgumentError" do
        assert_raises(ArgumentError) do
          CcdaGenerator.generate(
            patient: @patient,
            encounters: [ { date: "2026-03-01", type_code: "99213", type_display: "Office visit", performer: "Dr. Smith" } ]
          )
        end
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

        dob = doc.at_xpath("//xmlns:patient/xmlns:birthTime/@value", "xmlns" => "urn:hl7-org:v3")
        assert_equal "19750615", dob&.value
      end

      test "includes patient gender" do
        doc = parse_ccda

        gender = doc.at_xpath("//xmlns:patient/xmlns:administrativeGenderCode/@code", "xmlns" => "urn:hl7-org:v3")
        assert_equal "M", gender&.value
      end

      test "includes patient address from flat address attributes" do
        doc = parse_ccda
        ns = { "xmlns" => "urn:hl7-org:v3" }

        street = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:streetAddressLine", ns)
        city = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:city", ns)
        state = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:state", ns)
        zip = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:postalCode", ns)

        assert_equal "123 Main St", street&.text
        assert_equal "Anchorage", city&.text
        assert_equal "AK", state&.text
        assert_equal "99501", zip&.text
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

        assert_equal "20260301120000", effective&.value
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

      test "encounter entry uses Encounter type and period_start" do
        doc = parse_ccda
        ns = { "xmlns" => "urn:hl7-org:v3" }

        type_code = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]//xmlns:code/@code",
          ns
        )
        effective = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]//xmlns:effectiveTime/@value",
          ns
        )
        performer = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]//xmlns:performer//xmlns:text",
          ns
        )

        assert_equal "99213", type_code&.value
        assert_equal "20260301090000", effective&.value
        assert_equal "Dr. Smith", performer&.text
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
    end
  end
end
