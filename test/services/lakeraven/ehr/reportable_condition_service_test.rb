# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ReportableConditionServiceTest < ActiveSupport::TestCase
      setup do
        ReportableConditionService.reload!
        # Inject test data
        ReportableConditionService.define_singleton_method(:load_conditions) do
          [
            { code: "A15", category: "tb", jurisdiction: "NYS",
              reporting_timeframe: "24 hours" },
            { code: "A01.0", category: "enteric", jurisdiction: "NYS",
              reporting_timeframe: "24 hours" },
            { code: "B20", category: "hiv", jurisdiction: "NYS",
              reporting_timeframe: "5 days" }
          ]
        end
        ReportableConditionService.reload!
      end

      teardown do
        ReportableConditionService.reload!
      end

      # =========================================================================
      # EVALUATE — REPORTABLE MATCHES
      # =========================================================================

      test "evaluate returns reportable for exact code match" do
        condition = build_condition(code: "A01.0", display: "Typhoid fever")

        result = ReportableConditionService.evaluate(condition)

        assert result[:reportable]
        assert_equal "A01.0", result[:code]
        assert_equal "A01.0", result[:matched_trigger]
      end

      test "evaluate returns reportable for prefix match" do
        condition = build_condition(code: "A15.0", display: "TB lung, confirmed by sputum")

        result = ReportableConditionService.evaluate(condition)

        assert result[:reportable]
        assert_equal "A15", result[:matched_trigger]
      end

      test "evaluate includes jurisdiction and category" do
        condition = build_condition(code: "B20", display: "HIV disease")

        result = ReportableConditionService.evaluate(condition)

        assert_equal "NYS", result[:jurisdiction]
        assert_equal "hiv", result[:category]
      end

      test "evaluate includes trigger source" do
        condition = build_condition(code: "A15.0", display: "TB")

        result = ReportableConditionService.evaluate(condition)

        assert_match(/NYS Reportable/, result[:trigger_source])
      end

      test "evaluate includes reporting timeframe" do
        condition = build_condition(code: "B20", display: "HIV")

        result = ReportableConditionService.evaluate(condition)

        assert_equal "5 days", result[:reporting_timeframe]
      end

      # =========================================================================
      # EVALUATE — NON-REPORTABLE
      # =========================================================================

      test "evaluate returns not reportable for non-matching code" do
        condition = build_condition(code: "E11.9", display: "Type 2 diabetes")

        result = ReportableConditionService.evaluate(condition)

        refute result[:reportable]
        assert_equal "E11.9", result[:code]
      end

      test "evaluate returns not reportable for blank code" do
        condition = build_condition(code: nil, display: "Unknown")

        result = ReportableConditionService.evaluate(condition)

        refute result[:reportable]
      end

      # =========================================================================
      # ALL CONDITIONS
      # =========================================================================

      test "all_conditions returns loaded condition list" do
        conditions = ReportableConditionService.all_conditions
        assert_equal 3, conditions.length
        assert conditions.all? { |c| c.key?(:code) }
      end

      # =========================================================================
      # RELOAD
      # =========================================================================

      test "reload! clears cached conditions" do
        first = ReportableConditionService.all_conditions
        ReportableConditionService.reload!
        second = ReportableConditionService.all_conditions
        refute_equal first.object_id, second.object_id
      end

      private

      def build_condition(code:, display:)
        cond = Object.new
        cond.define_singleton_method(:code) { code }
        cond.define_singleton_method(:display) { display }
        cond
      end
    end
  end
end
