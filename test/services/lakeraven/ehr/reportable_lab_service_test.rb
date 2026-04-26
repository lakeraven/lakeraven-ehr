# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ReportableLabServiceTest < ActiveSupport::TestCase
      setup do
        ReportableLabService.reload!
        # Inject test data
        ReportableLabService.define_singleton_method(:load_tests) do
          [
            { loinc: "11585-7", category: "bacterial", jurisdiction: "NYS",
              organism_snomed: "9861002", organism_display: "Streptococcus pneumoniae",
              reporting_timeframe: "24 hours" },
            { loinc: "5671-3", category: "parasitic", jurisdiction: "NYS",
              organism_snomed: "34706006", organism_display: "Plasmodium falciparum",
              reporting_timeframe: "24 hours" }
          ]
        end
        ReportableLabService.reload!
      end

      teardown do
        ReportableLabService.reload!
      end

      # =========================================================================
      # EVALUATE — REPORTABLE MATCHES
      # =========================================================================

      test "evaluate returns reportable for matching LOINC code" do
        obs = build_observation(code: "11585-7", display: "S. pneumoniae culture")

        result = ReportableLabService.evaluate(obs)

        assert result[:reportable]
        assert_equal "11585-7", result[:loinc]
        assert_equal "11585-7", result[:matched_trigger]
        assert_equal "NYS", result[:jurisdiction]
      end

      test "evaluate includes category and organism info" do
        obs = build_observation(code: "11585-7", display: "S. pneumoniae")

        result = ReportableLabService.evaluate(obs)

        assert_equal "bacterial", result[:category]
        assert_equal "9861002", result[:organism_snomed]
        assert_equal "Streptococcus pneumoniae", result[:organism_display]
      end

      test "evaluate includes trigger source" do
        obs = build_observation(code: "11585-7", display: "test")

        result = ReportableLabService.evaluate(obs)

        assert_match(/NYS Reportable/, result[:trigger_source])
      end

      test "evaluate includes reporting timeframe" do
        obs = build_observation(code: "11585-7", display: "test")

        result = ReportableLabService.evaluate(obs)

        assert_equal "24 hours", result[:reporting_timeframe]
      end

      # =========================================================================
      # EVALUATE — NON-REPORTABLE
      # =========================================================================

      test "evaluate returns not reportable for non-matching code" do
        obs = build_observation(code: "99999-9", display: "Unrelated test")

        result = ReportableLabService.evaluate(obs)

        refute result[:reportable]
        assert_equal "99999-9", result[:loinc]
      end

      test "evaluate returns not reportable for blank code" do
        obs = build_observation(code: nil, display: "No code")

        result = ReportableLabService.evaluate(obs)

        refute result[:reportable]
      end

      # =========================================================================
      # ALL TESTS
      # =========================================================================

      test "all_tests returns loaded test list" do
        tests = ReportableLabService.all_tests
        assert_equal 2, tests.length
        assert tests.all? { |t| t.key?(:loinc) }
      end

      # =========================================================================
      # RELOAD
      # =========================================================================

      test "reload! clears cached tests" do
        first = ReportableLabService.all_tests
        ReportableLabService.reload!
        second = ReportableLabService.all_tests
        # After reload, may be same data but object identity differs
        refute_equal first.object_id, second.object_id
      end

      test "evaluate preserves display from observation" do
        obs = build_observation(code: "5671-3", display: "Malaria smear")

        result = ReportableLabService.evaluate(obs)

        assert_equal "Malaria smear", result[:display]
      end

      private

      def build_observation(code:, display:)
        obs = Object.new
        obs.define_singleton_method(:code) { code }
        obs.define_singleton_method(:display) { display }
        obs
      end
    end
  end
end
