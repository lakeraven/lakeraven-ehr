# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanServiceTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers
      include BrokerStubbing

      PROGRAM = "bh_outpatient"
      DFN = 1
      PROVIDER = "301"
      SUPERVISOR = "302"

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

      test "creating a plan persists in Postgres and issues no RPMS RPC" do
        use_broker(FakeBroker.new) do |broker|
          result = create_plan

          assert result.success?, result.error.inspect
          assert_equal 1, TreatmentPlan.count
          assert_empty broker.calls, "treatment plans must not write to shared RPMS files (#560)"
        end
      end

      test "creating a plan computes review due dates from configured intervals" do
        result = create_plan

        assert result.success?
        plan = result.record
        assert_equal Date.new(2026, 3, 2), plan.progress_review_due_on
        assert_equal Date.new(2026, 7, 1), plan.end_of_treatment_review_due_on
        assert_equal PROVIDER, plan.designated_provider_duz
        assert_equal "Synthetic narrative.", plan.narrative
        assert_equal [ { "problem" => "Example problem", "goal" => "Example goal" } ], plan.problems_goals
      end

      test "a different configured progress-review interval is honoured" do
        BehavioralHealthProgramConfiguration.assign(
          program_key: "bh_intensive",
          progress_review_interval: 90.days,
          end_of_treatment_review_interval: 6.months
        )

        result = create_plan(program_key: "bh_intensive")

        assert result.success?
        assert_equal Date.new(2026, 4, 1), result.record.progress_review_due_on
      end

      test "recording a progress review recomputes the next due date from the review date" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)

        review = service.record_progress_review(reviewed_on: Date.new(2026, 2, 15), reviewed_by_duz: PROVIDER)

        assert review.success?
        plan.reload
        assert_equal Date.new(2026, 4, 16), plan.progress_review_due_on
        assert_equal 1, plan.progress_reviews.count
        assert_equal Date.new(2026, 2, 15), plan.progress_reviews.first.reviewed_on
      end

      test "supervisor concurrence records who and when" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)
        at = Time.zone.parse("2026-01-05 09:30")

        result = service.record_concurrence(supervisor_duz: SUPERVISOR, concurred_at: at)

        assert result.success?
        concurrence = plan.reload.concurrence
        assert_equal SUPERVISOR, concurrence.supervisor_duz
        assert_equal at, concurrence.concurred_at
      end

      test "the designated provider cannot concur as supervisor" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)

        result = service.record_concurrence(
          supervisor_duz: PROVIDER,
          concurred_at: Time.zone.parse("2026-01-05")
        )

        refute result.success?
        assert_equal :supervisor_is_designated_provider, result.error
        assert_nil plan.reload.concurrence
      end
    end
  end
end
