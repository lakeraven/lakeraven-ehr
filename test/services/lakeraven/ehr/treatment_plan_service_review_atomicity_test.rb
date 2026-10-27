# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanServiceReviewAtomicityTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      PROGRAM = "bh_outpatient"
      DFN = 1
      PROVIDER = "301"

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

      def create_plan(**overrides)
        TreatmentPlanService.new(**{
          patient_dfn: DFN,
          program_key: PROGRAM,
          date_established: Date.new(2026, 1, 1),
          designated_provider_duz: PROVIDER,
          narrative: "Synthetic narrative.",
          problems_goals: [ { problem: "Example problem", goal: "Example goal" } ]
        }.merge(overrides)).create
      end

      def invalidate_problems_goals!(plan)
        plan.update_column(:problems_goals, [ "not a pair" ])
        plan.reload
      end

      test "record_progress_review rolls back the review row when due date update fails inside a caller transaction" do
        plan = create_plan.record
        invalidate_problems_goals!(plan)
        due_before = plan.progress_review_due_on
        service = TreatmentPlanService.new(plan: plan)

        TreatmentPlan.transaction do
          result = service.record_progress_review(
            reviewed_on: Date.new(2026, 2, 1),
            reviewed_by_duz: PROVIDER
          )

          refute result.success?
          assert_equal :invalid_review, result.error
        end

        plan.reload
        assert_equal 0, TreatmentPlanProgressReview.where(treatment_plan_id: plan.id).count
        assert_equal due_before, plan.progress_review_due_on
      end

      test "record_progress_review leaves no review row when due date update fails without a caller transaction" do
        plan = create_plan.record
        invalidate_problems_goals!(plan)
        due_before = plan.progress_review_due_on
        service = TreatmentPlanService.new(plan: plan)

        result = service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        )

        refute result.success?
        assert_equal :invalid_review, result.error

        plan.reload
        assert_equal 0, TreatmentPlanProgressReview.where(treatment_plan_id: plan.id).count
        assert_equal due_before, plan.progress_review_due_on
      end

      test "record_progress_review still records a review and updates due date inside a caller transaction for a valid plan" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)

        TreatmentPlan.transaction do
          result = service.record_progress_review(
            reviewed_on: Date.new(2026, 2, 1),
            reviewed_by_duz: PROVIDER
          )

          assert result.success?, result.error.inspect
        end

        plan.reload
        assert_equal 1, TreatmentPlanProgressReview.where(treatment_plan_id: plan.id).count
        assert_equal Date.new(2026, 4, 2), plan.progress_review_due_on
      end
    end
  end
end
