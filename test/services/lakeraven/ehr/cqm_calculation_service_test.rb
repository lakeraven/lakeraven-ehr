# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class CqmCalculationServiceTest < ActiveSupport::TestCase
      setup do
        @diabetes_measure = Measure.new(id: "CMS122v5", title: "Diabetes: Hemoglobin A1c Poor Control")
        @diabetes_measure.initial_population = { "resource_type" => "Condition", "valueset_id" => "2.16.840.1.113883.3.464.1003.103.12.1001" }
        @diabetes_measure.numerator = { "value_threshold" => 9.0, "value_comparator" => ">" }

        @screening_measure = Measure.new(id: "CMS130v5", title: "Colorectal Cancer Screening")
        @screening_measure.initial_population = { "resource_type" => "Patient" }
        @screening_measure.numerator = {}
      end

      test "evaluate returns MeasureReport for individual patient" do
        service = build_service(
          measure: @diabetes_measure,
          conditions: [ build_condition("pt_1", "2.16.840.1.113883.3.464.1003.103.12.1001") ],
          observations: [ build_observation("pt_1", 8.5, Date.new(2026, 3, 1)) ]
        )

        report = service.evaluate("CMS122v5", "pt_1", period: Date.new(2026, 1, 1)..Date.new(2026, 12, 31))

        assert_kind_of MeasureReport, report
        assert_equal "individual", report.report_type
        assert_equal 1, report.initial_population_count
        assert_equal 1, report.denominator_count
      end

      test "evaluate counts patient in numerator when threshold met" do
        service = build_service(
          measure: @diabetes_measure,
          conditions: [ build_condition("pt_1", "2.16.840.1.113883.3.464.1003.103.12.1001") ],
          observations: [ build_observation("pt_1", 9.5, Date.new(2026, 6, 1)) ]
        )

        report = service.evaluate("CMS122v5", "pt_1", period: Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
        assert_equal 1, report.numerator_count
      end

      test "evaluate excludes patient from numerator when threshold not met" do
        service = build_service(
          measure: @diabetes_measure,
          conditions: [ build_condition("pt_1", "2.16.840.1.113883.3.464.1003.103.12.1001") ],
          observations: [ build_observation("pt_1", 7.0, Date.new(2026, 6, 1)) ]
        )

        report = service.evaluate("CMS122v5", "pt_1", period: Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
        assert_equal 0, report.numerator_count
      end

      test "evaluate excludes patient without qualifying condition" do
        service = build_service(
          measure: @diabetes_measure,
          conditions: [ build_condition("pt_1", "other-valueset") ],
          observations: [ build_observation("pt_1", 9.5, Date.new(2026, 6, 1)) ]
        )

        report = service.evaluate("CMS122v5", "pt_1", period: Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
        assert_equal 0, report.initial_population_count
      end

      test "evaluate excludes observations outside measurement period" do
        service = build_service(
          measure: @diabetes_measure,
          conditions: [ build_condition("pt_1", "2.16.840.1.113883.3.464.1003.103.12.1001") ],
          observations: [ build_observation("pt_1", 9.5, Date.new(2025, 6, 1)) ]
        )

        report = service.evaluate("CMS122v5", "pt_1", period: Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
        assert_equal 0, report.numerator_count
      end

      test "evaluate_population aggregates across patients" do
        service = build_service(
          measure: @diabetes_measure,
          conditions: [
            build_condition("pt_1", "2.16.840.1.113883.3.464.1003.103.12.1001"),
            build_condition("pt_2", "2.16.840.1.113883.3.464.1003.103.12.1001")
          ],
          observations: [
            build_observation("pt_1", 9.5, Date.new(2026, 6, 1)),
            build_observation("pt_2", 7.0, Date.new(2026, 6, 1))
          ]
        )

        report = service.evaluate_population("CMS122v5", %w[pt_1 pt_2], period: Date.new(2026, 1, 1)..Date.new(2026, 12, 31))

        assert_equal "summary", report.report_type
        assert_equal 2, report.initial_population_count
        assert_equal 1, report.numerator_count
      end

      test "evaluate with presence-based numerator counts any observation" do
        service = build_service(
          measure: @screening_measure,
          conditions: [],
          observations: [ build_observation("pt_1", nil, Date.new(2026, 6, 1)) ]
        )

        report = service.evaluate("CMS130v5", "pt_1", period: Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
        assert_equal 1, report.numerator_count
      end

      private

      def build_service(measure:, conditions: [], observations: [])
        CqmCalculationService.new(
          conditions: conditions,
          observations: observations,
          measure_resolver: ->(_id) { measure }
        )
      end

      def build_condition(dfn, valueset_id)
        ::OpenStruct.new(dfn: dfn, valueset_id: valueset_id)
      end

      def build_observation(dfn, value, effective_date)
        ::OpenStruct.new(dfn: dfn, value: value, effective_date: effective_date)
      end
    end
  end
end
