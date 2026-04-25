# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MeasureReportTest < ActiveSupport::TestCase
      # ======================================================================
      # PERFORMANCE RATE
      # ======================================================================

      test "performance_rate calculates correctly" do
        report = MeasureReport.new(
          measure_id: "test",
          denominator_count: 10,
          numerator_count: 7
        )
        assert_equal 0.7, report.performance_rate
      end

      test "performance_rate returns nil when denominator is zero" do
        report = MeasureReport.new(
          measure_id: "test",
          denominator_count: 0,
          numerator_count: 0
        )
        assert_nil report.performance_rate
      end

      test "performance_rate accounts for exclusions" do
        report = MeasureReport.new(
          measure_id: "test",
          denominator_count: 10,
          numerator_count: 5,
          exclusion_count: 2
        )
        # effective denominator = 10 - 2 = 8
        assert_equal 0.625, report.performance_rate
      end

      test "performance_rate returns nil when effective denominator is zero" do
        report = MeasureReport.new(
          measure_id: "test",
          denominator_count: 5,
          numerator_count: 0,
          exclusion_count: 5
        )
        assert_nil report.performance_rate
      end

      test "performance_rate returns nil when exclusions exceed denominator" do
        report = MeasureReport.new(
          measure_id: "test",
          denominator_count: 3,
          numerator_count: 1,
          exclusion_count: 5
        )
        assert_nil report.performance_rate
      end

      # ======================================================================
      # INDIVIDUAL vs SUMMARY
      # ======================================================================

      test "individual report has patient-specific id" do
        report = MeasureReport.new(
          measure_id: "diabetes_a1c_control",
          patient_dfn: "123",
          report_type: "individual"
        )
        assert_equal "diabetes_a1c_control-123", report.id
      end

      test "summary report has summary id" do
        report = MeasureReport.new(
          measure_id: "diabetes_a1c_control",
          report_type: "summary"
        )
        assert_equal "diabetes_a1c_control-summary", report.id
      end

      test "report_type defaults to individual" do
        report = MeasureReport.new(measure_id: "test")
        assert_equal "individual", report.report_type
      end

      # ======================================================================
      # VALIDATIONS
      # ======================================================================

      test "validates presence of measure_id" do
        report = MeasureReport.new
        assert_not report.valid?
        assert_includes report.errors[:measure_id], "can't be blank"
      end

      test "validates report_type inclusion" do
        report = MeasureReport.new(measure_id: "test", report_type: "invalid")
        assert_not report.valid?
        assert report.errors[:report_type].any?
      end

      test "valid with correct attributes" do
        report = MeasureReport.new(
          measure_id: "diabetes_a1c_control",
          report_type: "individual",
          patient_dfn: "1"
        )
        assert report.valid?
      end

      # ======================================================================
      # FHIR SERIALIZATION (hash-based)
      # ======================================================================

      test "to_fhir produces valid MeasureReport" do
        report = MeasureReport.new(
          measure_id: "diabetes_a1c_control",
          patient_dfn: "1",
          report_type: "individual",
          period_start: Date.new(2025, 4, 1),
          period_end: Date.new(2026, 3, 31),
          initial_population_count: 1,
          denominator_count: 1,
          numerator_count: 1
        )

        fhir = report.to_fhir

        assert_equal "MeasureReport", fhir[:resourceType]
        assert_equal "complete", fhir[:status]
        assert_equal "individual", fhir[:type]
        assert_equal "Measure/diabetes_a1c_control", fhir[:measure]
        assert_equal "Patient/rpms-1", fhir.dig(:subject, :reference)
      end

      test "to_fhir includes population groups" do
        report = MeasureReport.new(
          measure_id: "test",
          report_type: "individual",
          patient_dfn: "1",
          initial_population_count: 1,
          denominator_count: 1,
          numerator_count: 1
        )

        fhir = report.to_fhir
        group = fhir[:group].first
        population_codes = group[:population].map { |p| p.dig(:code, :coding, 0, :code) }

        assert_includes population_codes, "initial-population"
        assert_includes population_codes, "denominator"
        assert_includes population_codes, "numerator"
      end

      test "to_fhir summary report has no subject" do
        report = MeasureReport.new(
          measure_id: "test",
          report_type: "summary",
          initial_population_count: 10,
          denominator_count: 10,
          numerator_count: 7
        )

        fhir = report.to_fhir
        assert_nil fhir[:subject]
        assert_equal "summary", fhir[:type]
      end

      test "to_fhir includes measure score for population reports" do
        report = MeasureReport.new(
          measure_id: "test",
          report_type: "summary",
          initial_population_count: 10,
          denominator_count: 10,
          numerator_count: 7
        )

        fhir = report.to_fhir
        assert_equal 0.7, fhir[:group].first[:measureScore][:value]
      end

      test "as_json produces serializable hash" do
        report = MeasureReport.new(
          measure_id: "test",
          report_type: "individual",
          patient_dfn: "1"
        )

        json = report.as_json
        assert_kind_of Hash, json
        assert_equal "MeasureReport", json[:resourceType]
      end
    end
  end
end
