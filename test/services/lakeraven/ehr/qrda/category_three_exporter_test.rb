# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module Qrda
      class CategoryThreeExporterTest < ActiveSupport::TestCase
        setup do
          @report = MeasureReport.new(
            measure_id: "diabetes_a1c_control",
            report_type: "summary",
            period_start: Date.new(2025, 4, 1),
            period_end: Date.new(2026, 3, 31),
            initial_population_count: 10,
            denominator_count: 10,
            numerator_count: 7,
            exclusion_count: 0
          )
        end

        # =====================================================================
        # DOCUMENT STRUCTURE
        # =====================================================================

        test "generates valid XML" do
          xml = generate_qrda_iii
          doc = Nokogiri::XML(xml) { |config| config.strict }
          assert doc.errors.empty?, "XML parse errors: #{doc.errors.join(', ')}"
        end

        test "contains QRDA III template ID" do
          xml = generate_qrda_iii
          doc = Nokogiri::XML(xml)
          template_ids = doc.xpath("//*[local-name()='templateId']").map { |t| t["root"] }
          assert_includes template_ids, "2.16.840.1.113883.10.20.27.1.1"
        end

        test "contains CDA R2 header template ID" do
          xml = generate_qrda_iii
          doc = Nokogiri::XML(xml)
          template_ids = doc.xpath("//*[local-name()='templateId']").map { |t| t["root"] }
          assert_includes template_ids, "2.16.840.1.113883.10.20.22.1.1"
        end

        test "contains LOINC code for quality reporting" do
          xml = generate_qrda_iii
          assert xml.include?("55184-6"), "Expected LOINC 55184-6 (Quality Reporting Document)"
        end

        # =====================================================================
        # MEASURE REFERENCE
        # =====================================================================

        test "includes measure reference with NQF number" do
          xml = generate_qrda_iii
          assert xml.include?("0059"), "Expected NQF 0059"
        end

        test "includes measurement period" do
          xml = generate_qrda_iii
          assert xml.include?("20250401"), "Expected period start"
          assert xml.include?("20260331"), "Expected period end"
        end

        # =====================================================================
        # AGGREGATE POPULATION COUNTS
        # =====================================================================

        test "includes initial population count" do
          xml = generate_qrda_iii
          doc = Nokogiri::XML(xml)
          ip_obs = find_population_observation(doc, "2.16.840.1.113883.10.20.27.3.5")
          assert ip_obs.present?, "Expected initial population observation"
          value = ip_obs.at_xpath(".//*[local-name()='value']")
          assert_equal "10", value["value"]
        end

        test "includes denominator count" do
          xml = generate_qrda_iii
          doc = Nokogiri::XML(xml)
          denom_obs = find_population_observation(doc, "2.16.840.1.113883.10.20.27.3.3")
          assert denom_obs.present?, "Expected denominator observation"
          value = denom_obs.at_xpath(".//*[local-name()='value']")
          assert_equal "10", value["value"]
        end

        test "includes numerator count" do
          xml = generate_qrda_iii
          doc = Nokogiri::XML(xml)
          num_obs = find_population_observation(doc, "2.16.840.1.113883.10.20.27.3.4")
          assert num_obs.present?, "Expected numerator observation"
          value = num_obs.at_xpath(".//*[local-name()='value']")
          assert_equal "7", value["value"]
        end

        # =====================================================================
        # PERFORMANCE RATE
        # =====================================================================

        test "includes performance rate" do
          xml = generate_qrda_iii
          doc = Nokogiri::XML(xml)
          perf_obs = find_population_observation(doc, "2.16.840.1.113883.10.20.27.3.14")
          assert perf_obs.present?, "Expected performance rate observation"
          value = perf_obs.at_xpath(".//*[local-name()='value']")
          assert_equal "0.7", value["value"]
        end

        test "handles zero denominator gracefully" do
          @report.initial_population_count = 0
          @report.denominator_count = 0
          @report.numerator_count = 0

          xml = generate_qrda_iii
          doc = Nokogiri::XML(xml) { |config| config.strict }
          assert doc.errors.empty?
        end

        # =====================================================================
        # PERFORMANCE
        # =====================================================================

        test "generation completes within 2 seconds" do
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          generate_qrda_iii
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          assert elapsed < 2.0, "QRDA III generation took #{elapsed}s"
        end

        private

        def generate_qrda_iii
          CategoryThreeExporter.generate(measure_report: @report)
        end

        def find_population_observation(doc, template_id)
          doc.xpath("//*[local-name()='observation']").find do |obs|
            obs.xpath(".//*[local-name()='templateId']").any? { |t| t["root"] == template_id }
          end
        end
      end
    end
  end
end
