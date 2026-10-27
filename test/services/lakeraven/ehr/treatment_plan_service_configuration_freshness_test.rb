# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanServiceConfigurationFreshnessTest < ActiveSupport::TestCase
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

      test "record_progress_review applies reassigned progress interval when the same service instance is reused" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)

        first = service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        )
        assert first.success?, first.error.inspect
        plan.reload
        assert_equal Date.new(2026, 2, 1) + 60.days, plan.progress_review_due_on

        BehavioralHealthProgramConfiguration.assign(
          program_key: PROGRAM,
          progress_review_interval: 90.days,
          end_of_treatment_review_interval: 6.months
        )

        second = service.record_progress_review(
          reviewed_on: Date.new(2026, 3, 1),
          reviewed_by_duz: PROVIDER
        )
        assert second.success?, second.error.inspect
        plan.reload

        expected_due = Date.new(2026, 3, 1) + 90.days
        assert_equal Date.new(2026, 5, 30), plan.progress_review_due_on
        assert_equal expected_due, plan.progress_review_due_on

        parity_plan = create_plan.record
        parity_service = TreatmentPlanService.new(plan: parity_plan)
        assert parity_service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        ).success?
        BehavioralHealthProgramConfiguration.assign(
          program_key: PROGRAM,
          progress_review_interval: 90.days,
          end_of_treatment_review_interval: 6.months
        )
        fresh_service = TreatmentPlanService.new(plan: parity_plan.reload)
        assert fresh_service.record_progress_review(
          reviewed_on: Date.new(2026, 3, 1),
          reviewed_by_duz: PROVIDER
        ).success?
        assert_equal parity_plan.reload.progress_review_due_on, plan.progress_review_due_on
      end

      test "record_progress_review returns invalid_program_configuration when progress parts become malformed on a reused service instance" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)

        assert service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        ).success?

        BehavioralHealthProgramConfiguration.for_program(PROGRAM).update_column(
          :progress_review_interval_parts,
          "60"
        )

        result = service.record_progress_review(
          reviewed_on: Date.new(2026, 3, 1),
          reviewed_by_duz: PROVIDER
        )

        refute result.success?
        assert_equal :invalid_program_configuration, result.error
        plan.reload
        assert_equal 1, plan.progress_reviews.count
      end

      test "record_progress_review returns unknown_program when configuration is deleted on a reused service instance" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)

        assert service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        ).success?

        BehavioralHealthProgramConfiguration.reset!

        result = service.record_progress_review(
          reviewed_on: Date.new(2026, 3, 1),
          reviewed_by_duz: PROVIDER
        )

        refute result.success?
        assert_equal :unknown_program, result.error
        plan.reload
        assert_equal 1, plan.progress_reviews.count
      end
    end
  end
end
