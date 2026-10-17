# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanGateR1Test < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      PROGRAM = "bh_outpatient"
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

      def create_plan(established_on: Date.new(2026, 1, 1))
        TreatmentPlanService.new(
          patient_dfn: 1,
          program_key: PROGRAM,
          date_established: established_on,
          designated_provider_duz: PROVIDER,
          narrative: "Synthetic narrative.",
          problems_goals: [ { problem: "Example problem", goal: "Example goal" } ]
        ).create.record
      end

      test "a backdated progress review is stored but the due date stays computed from the latest review date" do
        plan = create_plan
        service = TreatmentPlanService.new(plan: plan)

        assert service.record_progress_review(
          reviewed_on: Date.new(2026, 3, 15),
          reviewed_by_duz: PROVIDER
        ).success?
        plan.reload
        assert_equal Date.new(2026, 5, 14), plan.progress_review_due_on

        result = service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        )

        assert result.success?, result.error.inspect
        plan.reload
        assert_equal 2, plan.progress_reviews.count
        assert_equal Date.new(2026, 5, 14), plan.progress_review_due_on
      end

      test "assign rejects zero, negative, and sub-day review intervals" do
        valid_other = 6.months
        invalid_intervals = [ 0.days, -5.days, 1.hour ]

        invalid_intervals.each do |interval|
          assert_raises(ArgumentError) do
            BehavioralHealthProgramConfiguration.assign(
              program_key: "gate_r1_progress_#{interval.inspect.tr(' ', '_')}",
              progress_review_interval: interval,
              end_of_treatment_review_interval: valid_other
            )
          end

          assert_raises(ArgumentError) do
            BehavioralHealthProgramConfiguration.assign(
              program_key: "gate_r1_eot_#{interval.inspect.tr(' ', '_')}",
              progress_review_interval: 60.days,
              end_of_treatment_review_interval: interval
            )
          end
        end
      end
    end
  end
end
