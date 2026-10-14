# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanWorklistTest < ActiveSupport::TestCase
      teardown do
        TreatmentPlanReview.delete_all
        TreatmentPlan.delete_all
      end

      def establish(dfn, on)
        TreatmentPlan.establish!(patient_dfn: dfn, established_on: on, designated_provider: "99999")
      end

      test "the reviews-overdue preset counts and lists overdue plans, oldest due first" do
        later = establish(2, Date.new(2026, 9, 15))
        earlier = establish(1, Date.new(2026, 9, 1))
        establish(3, Date.new(2026, 12, 1))

        preset = TreatmentPlanWorklist.new(as_of: Date.new(2026, 12, 15)).preset("reviews-overdue")

        assert_equal "Reviews overdue", preset.label
        assert_equal 2, preset.count
        assert_equal [ earlier, later ], preset.plans.to_a
      end

      test "every preset carries its count before it is selected" do
        establish(1, Date.new(2026, 9, 1))
        presets = TreatmentPlanWorklist.new(as_of: Date.new(2026, 12, 15)).presets

        assert_equal [ "reviews-overdue" ], presets.map(&:key)
        assert_equal [ 1 ], presets.map(&:count)
      end

      test "an unknown preset is refused rather than read as an empty list" do
        assert_raises(KeyError) { TreatmentPlanWorklist.new.preset("everything") }
      end
    end
  end
end
