# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EicrGeneratorTest < ActiveSupport::TestCase
      setup do
        @condition = Condition.new(
          ien: "cond-001", patient_dfn: "12345",
          code: "A15.0", code_system: "icd10",
          display: "Tuberculosis of lung",
          clinical_status: "active", verification_status: "confirmed"
        )
        @patient = {
          dfn: "12345",
          name: { given: "Alice", family: "Anderson" },
          dob: "1975-06-15", sex: "F",
          address: { street: "123 Main St", city: "Kingston", state: "NY", zip: "12401" }
        }
        @encounter = {
          date: "2026-03-16", type_code: "99213",
          type_display: "Office visit", facility: "Healthcare Facility"
        }
        @provider = { duz: "789", name: "Dr. Smith", npi: "1234567890" }
      end

      # =========================================================================
      # DOCUMENT STRUCTURE
      # =========================================================================

      test "generates valid XML" do
        xml = generate_eicr
        doc = Nokogiri::XML(xml) { |config| config.strict }

        assert doc.errors.empty?, "Expected valid XML: #{doc.errors.map(&:message)}"
      end

      test "includes eICR template ID" do
        doc = parse_eicr

        templates = doc.xpath("//xmlns:templateId/@root", "xmlns" => "urn:hl7-org:v3").map(&:value)
        assert_includes templates, "2.16.840.1.113883.10.20.15.2"
      end

      test "includes ClinicalDocument root element" do
        doc = parse_eicr

        root = doc.at_xpath("//xmlns:ClinicalDocument", "xmlns" => "urn:hl7-org:v3")
        assert root.present?, "Expected ClinicalDocument root"
      end

      # =========================================================================
      # PATIENT DEMOGRAPHICS
      # =========================================================================

      test "includes patient name" do
        doc = parse_eicr

        given = doc.at_xpath("//xmlns:patient/xmlns:name/xmlns:given", "xmlns" => "urn:hl7-org:v3")
        family = doc.at_xpath("//xmlns:patient/xmlns:name/xmlns:family", "xmlns" => "urn:hl7-org:v3")
        assert_equal "Alice", given&.text
        assert_equal "Anderson", family&.text
      end

      test "includes patient address" do
        doc = parse_eicr

        state = doc.at_xpath("//xmlns:patientRole/xmlns:addr/xmlns:state", "xmlns" => "urn:hl7-org:v3")
        assert_equal "NY", state&.text
      end

      # =========================================================================
      # REPORTABLE CONDITION
      # =========================================================================

      test "includes reportable condition with ICD-10 code" do
        doc = parse_eicr

        code = doc.at_xpath("//xmlns:value[@code='A15.0']", "xmlns" => "urn:hl7-org:v3")
        assert code.present?, "Expected condition code A15.0"
      end

      # =========================================================================
      # AUTHOR / PROVIDER
      # =========================================================================

      test "includes author section" do
        doc = parse_eicr

        author = doc.at_xpath("//xmlns:author", "xmlns" => "urn:hl7-org:v3")
        assert author.present?, "Expected author"
      end

      # =========================================================================
      # ENCOUNTER
      # =========================================================================

      test "includes encompassing encounter" do
        doc = parse_eicr

        encounter = doc.at_xpath("//xmlns:encompassingEncounter", "xmlns" => "urn:hl7-org:v3")
        assert encounter.present?, "Expected encompassingEncounter"
      end

      # =========================================================================
      # PERFORMANCE
      # =========================================================================

      test "generation completes within 2 seconds" do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        generate_eicr
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

        assert elapsed < 2.0, "eICR generation took #{elapsed}s"
      end

      private

      def generate_eicr
        EicrGenerator.generate(
          condition: @condition, patient: @patient,
          encounter: @encounter, provider: @provider
        )
      end

      def parse_eicr
        Nokogiri::XML(generate_eicr)
      end
    end
  end
end
