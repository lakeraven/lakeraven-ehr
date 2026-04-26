# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CcdaGeneratorTest < ActiveSupport::TestCase
      setup do
        @patient_data = {
          dfn: "12345",
          name: { given: "John", family: "Doe" },
          dob: "1975-06-15",
          sex: "M",
          address: { street: "123 Main St", city: "Anchorage", state: "AK", zip: "99501" }
        }
        @allergies = [
          { code: "7980", code_system: "2.16.840.1.113883.6.88", display: "Penicillin", status: "active" },
          { code: "36567", code_system: "2.16.840.1.113883.6.88", display: "Simvastatin", status: "active" }
        ]
        @conditions = [
          { code: "E11.9", code_system: "2.16.840.1.113883.6.90", display: "Type 2 diabetes mellitus", status: "active" },
          { code: "I10", code_system: "2.16.840.1.113883.6.90", display: "Essential hypertension", status: "active" }
        ]
        @medications = [
          { code: "311364", code_system: "2.16.840.1.113883.6.88", display: "Lisinopril 10 MG Oral Tablet" },
          { code: "860975", code_system: "2.16.840.1.113883.6.88", display: "Metformin 500 MG Oral Tablet" }
        ]
        @vitals = [
          { code: "8480-6", display: "Systolic BP", value: "120", units: "mm[Hg]", date: "2026-03-01" }
        ]
        @encounters = [
          { date: "2026-03-01", type_code: "99213", type_display: "Office visit", performer: "Dr. Smith" }
        ]
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
      # PATIENT DEMOGRAPHICS
      # =============================================================================

      test "includes patient name" do
        doc = parse_ccda

        given = doc.at_xpath("//xmlns:patient/xmlns:name/xmlns:given", "xmlns" => "urn:hl7-org:v3")
        family = doc.at_xpath("//xmlns:patient/xmlns:name/xmlns:family", "xmlns" => "urn:hl7-org:v3")
        assert_equal "John", given&.text
        assert_equal "Doe", family&.text
      end

      test "includes patient DFN as ID" do
        doc = parse_ccda

        id = doc.at_xpath("//xmlns:patientRole/xmlns:id/@extension", "xmlns" => "urn:hl7-org:v3")
        assert_equal "12345", id&.value
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

      test "includes encounters section" do
        doc = parse_ccda

        encounters_template = doc.at_xpath(
          "//xmlns:section[xmlns:templateId[@root='2.16.840.1.113883.10.20.22.2.22.1']]",
          "xmlns" => "urn:hl7-org:v3"
        )
        assert encounters_template.present?, "Expected encounters section"
      end

      # =============================================================================
      # AUTHOR AND CUSTODIAN
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

      test "parsed allergy codes match input" do
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
        xml = CcdaGenerator.generate(patient: @patient_data, allergies: [], conditions: @conditions, medications: @medications)
        doc = Nokogiri::XML(xml)

        assert doc.errors.empty?, "Expected valid XML with empty allergies"
      end

      test "generates document with empty clinical data" do
        xml = CcdaGenerator.generate(patient: @patient_data, allergies: [], conditions: [], medications: [])
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
          patient: @patient_data,
          allergies: @allergies,
          conditions: @conditions,
          medications: @medications,
          vitals: @vitals,
          encounters: @encounters,
          author: { name: "Dr. Smith", institution: "IHS Facility" }
        )
      end

      def parse_ccda
        xml = generate_ccda
        Nokogiri::XML(xml)
      end
    end
  end
end
