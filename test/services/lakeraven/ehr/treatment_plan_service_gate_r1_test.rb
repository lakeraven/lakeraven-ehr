# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanServiceGateR1Test < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      PROGRAM = "bh_outpatient"
      DFN = 1
      PROVIDER = "301"
      SUPERVISOR = "302"
      UNKNOWN_PROGRAM = "gate_r1_unknown_program"

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

      test "record_progress_review refuses a reviewed_on date in the future" do
        plan = create_plan.record
        due_before = plan.progress_review_due_on
        service = TreatmentPlanService.new(plan: plan)

        travel_to Time.zone.parse("2026-06-01").middle_of_day do
          result = service.record_progress_review(
            reviewed_on: Date.current + 1.day,
            reviewed_by_duz: PROVIDER
          )

          refute result.success?
          assert_equal :reviewed_on_in_future, result.error
          plan.reload
          assert_equal 0, plan.progress_reviews.count
          assert_equal due_before, plan.progress_review_due_on
        end
      end

      test "create with empty problems and goals returns invalid_plan and persists no plan" do
        result = create_plan(problems_goals: [])

        refute result.success?
        assert_equal :invalid_plan, result.error
        assert_equal 0, TreatmentPlan.count
      end

      test "a second record_concurrence is refused and leaves the original concurrence unchanged" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)
        first_at = Time.zone.parse("2026-01-05 09:30")

        assert service.record_concurrence(supervisor_duz: SUPERVISOR, concurred_at: first_at).success?

        second_at = Time.zone.parse("2026-01-06 10:00")
        result = service.record_concurrence(supervisor_duz: "303", concurred_at: second_at)

        refute result.success?
        assert_equal :already_concurred, result.error
        concurrence = plan.reload.concurrence
        assert_equal SUPERVISOR, concurrence.supervisor_duz
        assert_equal first_at, concurrence.concurred_at
      end

      test "invalid create and review inputs return failed Results without raising" do
        nil_established = TreatmentPlanService.new(
          patient_dfn: DFN,
          program_key: PROGRAM,
          date_established: nil,
          designated_provider_duz: PROVIDER,
          narrative: "Synthetic narrative.",
          problems_goals: [ { problem: "Example problem", goal: "Example goal" } ]
        ).create
        refute nil_established.success?
        assert_equal :invalid_plan, nil_established.error

        unknown = create_plan(program_key: UNKNOWN_PROGRAM)
        refute unknown.success?
        assert_equal :unknown_program, unknown.error

        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)
        invalid_review = service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: nil
        )
        refute invalid_review.success?
        assert_equal :invalid_review, invalid_review.error
        assert_equal 0, plan.reload.progress_reviews.count
      end

      test "record_concurrence refuses a supervisor DUZ that normalizes to the designated provider" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)
        at = Time.zone.parse("2026-01-05")

        [ " 301", "0301" ].each do |supervisor_duz|
          result = service.record_concurrence(supervisor_duz: supervisor_duz, concurred_at: at)

          refute result.success?, "expected refusal for supervisor_duz #{supervisor_duz.inspect}"
          assert_equal :supervisor_is_designated_provider, result.error
          assert_nil plan.reload.concurrence
        end
      end
    end
  end
end
