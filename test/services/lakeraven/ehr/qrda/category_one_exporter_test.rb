# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module Qrda
      class CategoryOneExporterTest < ActiveSupport::TestCase
        setup do
          @report = MeasureReport.new(
            measure_id: "diabetes_a1c_control",
            patient_dfn: "1",
            report_type: "individual",
            period_start: Date.new(2025, 4, 1),
            period_end: Date.new(2026, 3, 31),
            initial_population_count: 1,
            denominator_count: 1,
            numerator_count: 1,
            exclusion_count: 0
          )
          @patient = {
            dfn: "1",
            name: { given: "Alice", family: "Anderson" },
            dob: "1980-05-15", sex: "F"
          }
          @conditions = [
            Condition.new(
              ien: "cond-1", patient_dfn: "1",
              code: "E11.9", code_system: "icd10",
              display: "Type 2 diabetes mellitus", clinical_status: "active"
            )
          ]
          @observations = [
            Observation.new(
              ien: "obs-1", patient_dfn: "1",
              category: "laboratory", code: "4548-4", code_system: "loinc",
              display: "Hemoglobin A1c", value: "7.5", value_quantity: 7.5,
              unit: "%", status: "final",
              effective_datetime: DateTime.new(2026, 1, 15)
            )
          ]
        end

        # =====================================================================
        # DOCUMENT STRUCTURE
        # =====================================================================

        test "generates valid XML" do
          xml = generate_qrda_i
          doc = Nokogiri::XML(xml) { |config| config.strict }
          assert doc.errors.empty?, "XML parse errors: #{doc.errors.join(', ')}"
        end

        test "contains QRDA I template ID" do
          xml = generate_qrda_i
          doc = Nokogiri::XML(xml)
          template_ids = doc.xpath("//*[local-name()='templateId']").map { |t| t["root"] }
          assert_includes template_ids, "2.16.840.1.113883.10.20.24.1.1"
        end

        test "contains CDA R2 header template ID" do
          xml = generate_qrda_i
          doc = Nokogiri::XML(xml)
          template_ids = doc.xpath("//*[local-name()='templateId']").map { |t| t["root"] }
          assert_includes template_ids, "2.16.840.1.113883.10.20.22.1.1"
        end

        test "contains LOINC code for quality reporting" do
          xml = generate_qrda_i
          assert xml.include?("55182-0"), "Expected LOINC 55182-0 (Quality Measure Report)"
        end

        # =====================================================================
        # PATIENT DEMOGRAPHICS
        # =====================================================================

        test "includes patient name in recordTarget" do
          xml = generate_qrda_i
          doc = Nokogiri::XML(xml)
          given = doc.at_xpath("//*[local-name()='recordTarget']//*[local-name()='given']")
          family = doc.at_xpath("//*[local-name()='recordTarget']//*[local-name()='family']")
          assert_equal "Alice", given.text
          assert_equal "Anderson", family.text
        end

        test "includes patient DOB" do
          xml = generate_qrda_i
          assert xml.include?("19800515"), "Expected DOB 19800515"
        end

        test "includes patient sex" do
          xml = generate_qrda_i
          doc = Nokogiri::XML(xml)
          gender = doc.at_xpath("//*[local-name()='administrativeGenderCode']")
          assert_equal "F", gender["code"]
        end

        # =====================================================================
        # MEASURE REFERENCE
        # =====================================================================

        test "includes measure section with NQF number" do
          xml = generate_qrda_i
          assert xml.include?("0059"), "Expected NQF 0059"
        end

        test "includes measurement period" do
          xml = generate_qrda_i
          assert xml.include?("20250401"), "Expected period start"
          assert xml.include?("20260331"), "Expected period end"
        end

        # =====================================================================
        # CLINICAL DATA ENTRIES
        # =====================================================================

        test "includes condition entry with ICD-10 code" do
          xml = generate_qrda_i
          assert xml.include?("E11.9"), "Expected ICD-10 code E11.9"
        end

        test "includes observation entry with LOINC code" do
          xml = generate_qrda_i
          assert xml.include?("4548-4"), "Expected LOINC code 4548-4"
        end

        test "includes observation value" do
          xml = generate_qrda_i
          assert xml.include?("7.5"), "Expected observation value 7.5"
        end

        # =====================================================================
        # POPULATION CRITERIA
        # =====================================================================

        test "includes initial population result" do
          xml = generate_qrda_i
          assert xml.include?("2.16.840.1.113883.10.20.27.3.5"),
            "Expected initial population template"
        end

        test "includes denominator result" do
          xml = generate_qrda_i
          assert xml.include?("2.16.840.1.113883.10.20.27.3.3"),
            "Expected denominator template"
        end

        test "includes numerator result" do
          xml = generate_qrda_i
          assert xml.include?("2.16.840.1.113883.10.20.27.3.4"),
            "Expected numerator template"
        end

        # =====================================================================
        # EDGE CASES
        # =====================================================================

        test "handles patient not in initial population" do
          @report.initial_population_count = 0
          @report.denominator_count = 0
          @report.numerator_count = 0
          xml = generate_qrda_i

          doc = Nokogiri::XML(xml) { |config| config.strict }
          assert doc.errors.empty?
        end

        test "handles nil observation value" do
          @observations = [
            Observation.new(
              ien: "obs-nil", patient_dfn: "1",
              category: "laboratory", code: "4548-4", code_system: "loinc",
              display: "Hemoglobin A1c", value: nil, value_quantity: nil,
              status: "final", effective_datetime: DateTime.new(2026, 1, 15)
            )
          ]
          xml = generate_qrda_i
          doc = Nokogiri::XML(xml) { |config| config.strict }
          assert doc.errors.empty?
        end

        test "handles empty conditions and observations" do
          xml = CategoryOneExporter.generate(
            measure_report: @report,
            patient: @patient,
            conditions: [],
            observations: []
          )
          doc = Nokogiri::XML(xml) { |config| config.strict }
          assert doc.errors.empty?
        end

        # =====================================================================
        # PERFORMANCE
        # =====================================================================

        test "generation completes within 2 seconds" do
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          generate_qrda_i
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          assert elapsed < 2.0, "QRDA I generation took #{elapsed}s"
        end

        private

        def generate_qrda_i
          CategoryOneExporter.generate(
            measure_report: @report,
            patient: @patient,
            conditions: @conditions,
            observations: @observations
          )
        end
      end
    end
  end
end
