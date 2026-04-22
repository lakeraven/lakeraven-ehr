# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    class CqmTest < ActiveSupport::TestCase
      # -- Measure loading -----------------------------------------------------

      test "Measure.find loads a measure from YAML" do
        measure = Measure.find("diabetes_a1c_control")
        assert_not_nil measure
        assert_equal "diabetes_a1c_control", measure.id
        assert_equal "proportion", measure.scoring
      end

      test "Measure.all returns all configured measures" do
        measures = Measure.all
        assert_operator measures.size, :>=, 3
      end

      test "Measure.find returns nil for unknown measure" do
        assert_nil Measure.find("nonexistent")
      end

      # -- CQM evaluation (individual) ----------------------------------------

      test "diabetic with controlled A1C is in numerator" do
        service = CqmCalculationService.new(
          conditions: [ condition("E11.9", "gpra-bgpmu-diabetes-dx") ],
          observations: [ observation("4548-4", 7.5, "2026-01-15") ]
        )
        report = service.evaluate("diabetes_a1c_control", "1",
          period: Date.new(2025, 4, 1)..Date.new(2026, 3, 31))

        assert_equal 1, report.initial_population_count
        assert_equal 1, report.numerator_count
      end

      test "diabetic with uncontrolled A1C is not in numerator" do
        service = CqmCalculationService.new(
          conditions: [ condition("E11.9", "gpra-bgpmu-diabetes-dx") ],
          observations: [ observation("4548-4", 10.2, "2026-01-15") ]
        )
        report = service.evaluate("diabetes_a1c_control", "1",
          period: Date.new(2025, 4, 1)..Date.new(2026, 3, 31))

        assert_equal 1, report.initial_population_count
        assert_equal 0, report.numerator_count
      end

      test "non-diabetic is not in initial population" do
        service = CqmCalculationService.new(conditions: [], observations: [])
        report = service.evaluate("diabetes_a1c_control", "2",
          period: Date.new(2025, 4, 1)..Date.new(2026, 3, 31))

        assert_equal 0, report.initial_population_count
      end

      # -- Population evaluation -----------------------------------------------

      test "population report aggregates across patients" do
        service = CqmCalculationService.new(
          conditions: [ condition("E11.9", "gpra-bgpmu-diabetes-dx") ],
          observations: [ observation("4548-4", 7.5, "2026-01-15") ]
        )
        report = service.evaluate_population("diabetes_a1c_control", %w[1 2],
          period: Date.new(2025, 4, 1)..Date.new(2026, 3, 31))

        # Both patients get same data in this simplified test
        assert_equal 2, report.initial_population_count
        assert_equal 2, report.numerator_count
      end

      # -- MeasureReport FHIR --------------------------------------------------

      test "MeasureReport serializes to FHIR" do
        report = MeasureReport.new(
          measure_id: "diabetes_a1c_control", report_type: "individual",
          initial_population_count: 1, denominator_count: 1, numerator_count: 1
        )
        fhir = report.to_fhir
        assert_equal "MeasureReport", fhir[:resourceType]
        assert fhir[:group].first[:population].any?
      end

      private

      def condition(code, valueset)
        ::OpenStruct.new(code: code, valueset_id: valueset)
      end

      def observation(code, value, date)
        ::OpenStruct.new(code: code, value: value, effective_date: Date.parse(date))
      end
    end
  end
end
