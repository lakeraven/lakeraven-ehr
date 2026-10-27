# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      PROGRAM = "bh_outpatient"

      setup do
        BehavioralHealthProgramConfiguration.reset!
        BehavioralHealthProgramConfiguration.assign(
          program_key: PROGRAM,
          progress_review_interval: 60.days,
          end_of_treatment_review_interval: 6.months
        )
        TreatmentPlanProgressReview.delete_all if defined?(TreatmentPlanProgressReview)
        TreatmentPlanConcurrence.delete_all if defined?(TreatmentPlanConcurrence)
        TreatmentPlan.delete_all if defined?(TreatmentPlan)
      end

      def create_plan(established_on: Date.new(2026, 1, 1))
        TreatmentPlanService.new(
          patient_dfn: 1,
          program_key: PROGRAM,
          date_established: established_on,
          designated_provider_duz: "301",
          narrative: "Synthetic narrative.",
          problems_goals: [ { problem: "Example problem", goal: "Example goal" } ]
        ).create.record
      end

      test "default program configuration exposes a 60-day progress-review interval" do
        BehavioralHealthProgramConfiguration.reset!
        BehavioralHealthProgramConfiguration.seed_defaults!

        config = BehavioralHealthProgramConfiguration.for_program(PROGRAM)

        assert_equal 60.days, config.progress_review_interval
      end

      test "due today is not overdue" do
        plan = create_plan

        travel_to Time.zone.parse("2026-03-02").middle_of_day do
          refute plan.progress_review_overdue?(as_of: Date.current)
          assert_empty TreatmentPlan.progress_review_overdue(as_of: Date.current)
        end
      end

      test "due yesterday is overdue" do
        plan = create_plan

        travel_to Time.zone.parse("2026-03-03").middle_of_day do
          assert plan.progress_review_overdue?(as_of: Date.current)
          assert_includes TreatmentPlan.progress_review_overdue(as_of: Date.current), plan
          assert_equal 1, TreatmentPlan.progress_review_overdue_count(as_of: Date.current)
        end
      end

      test "a late review recomputes the next due date so the plan is not overdue on the new due date" do
        plan = create_plan
        TreatmentPlanService.new(plan: plan).record_progress_review(
          reviewed_on: Date.new(2026, 3, 15),
          reviewed_by_duz: "301"
        )
        plan.reload

        assert_equal Date.new(2026, 5, 14), plan.progress_review_due_on

        travel_to Time.zone.parse("2026-05-14").middle_of_day do
          refute plan.progress_review_overdue?(as_of: Date.current)
        end
      end

      test "a plan with no progress-review due date is not treated as safely not overdue" do
        plan = create_plan
        plan.update_column(:progress_review_due_on, nil)

        travel_to Time.zone.parse("2026-03-03").middle_of_day do
          assert_raises(TreatmentPlan::IndeterminateCompliance) do
            plan.progress_review_overdue?(as_of: Date.current)
          end
          # Spec amendment (chair, r0): an unknown due date must surface, not
          # vanish. Excluding it from the overdue query alone would drop the
          # plan off every worklist (absence of data read as compliance).
          refute_includes TreatmentPlan.progress_review_overdue(as_of: Date.current), plan
          assert_includes TreatmentPlan.progress_review_indeterminate, plan
        end
      end
    end
  end
end
