# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthProgramConfigurationIntervalOrderTest < ActiveSupport::TestCase
      ANCHOR = Date.new(2026, 1, 30)
      EXPECTED_DUE = Date.new(2026, 3, 1)

      setup do
        BehavioralHealthProgramConfiguration.reset!
      end

      test "duration_from adds one month then one day regardless of parts hash key order" do
        days_first = { "days" => 1, "months" => 1 }
        months_first = { "months" => 1, "days" => 1 }

        assert_equal EXPECTED_DUE, ANCHOR + BehavioralHealthProgramConfiguration.duration_from(days_first)
        assert_equal EXPECTED_DUE, ANCHOR + BehavioralHealthProgramConfiguration.duration_from(months_first)
      end

      test "assigning month plus day interval survives jsonb reload with canonical unit order" do
        program_key = "interval_order_assign_month_day"
        BehavioralHealthProgramConfiguration.assign(
          program_key: program_key,
          progress_review_interval: 1.month + 1.day,
          end_of_treatment_review_interval: 6.months
        )

        reloaded = BehavioralHealthProgramConfiguration.for_program(program_key).reload

        assert_equal EXPECTED_DUE, ANCHOR + reloaded.progress_review_interval
      end

      test "progress_review_interval after jsonb stores days before months applies months before days" do
        program_key = "interval_order_month_plus_day"
        BehavioralHealthProgramConfiguration.assign(
          program_key: program_key,
          progress_review_interval: 60.days,
          end_of_treatment_review_interval: 6.months
        )
        record = BehavioralHealthProgramConfiguration.for_program(program_key)
        record.update_column(:progress_review_interval_parts, { "days" => 1, "months" => 1 })

        reloaded = BehavioralHealthProgramConfiguration.find(record.id)

        assert_equal EXPECTED_DUE, ANCHOR + reloaded.progress_review_interval
      end
    end
  end
end
