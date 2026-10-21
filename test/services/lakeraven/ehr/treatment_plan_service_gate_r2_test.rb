# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanServiceGateR2Test < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

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

      test "record_concurrence refuses blank supervisor_duz or nil concurred_at without raising" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)
        valid_at = Time.zone.parse("2026-01-05 09:30")

        [
          { supervisor_duz: "", concurred_at: valid_at },
          { supervisor_duz: SUPERVISOR, concurred_at: nil }
        ].each do |attrs|
          result = service.record_concurrence(**attrs)

          refute result.success?, attrs.inspect
          assert_equal :invalid_concurrence, result.error
          assert_nil plan.reload.concurrence
          assert_equal 0, TreatmentPlanConcurrence.count
        end
      end

      test "record_concurrence returns already_concurred when a row exists and pre-check is bypassed" do
        plan = create_plan.record
        first_at = Time.zone.parse("2026-01-05 09:30")
        service = TreatmentPlanService.new(plan: plan)

        assert service.record_concurrence(supervisor_duz: SUPERVISOR, concurred_at: first_at).success?

        service.define_singleton_method(:concurrence_recorded?) { false }
        second_at = Time.zone.parse("2026-01-06 10:00")
        result = service.record_concurrence(supervisor_duz: "303", concurred_at: second_at)

        refute result.success?
        assert_equal :already_concurred, result.error
        concurrence = plan.reload.concurrence
        assert_equal SUPERVISOR, concurrence.supervisor_duz
        assert_equal first_at, concurrence.concurred_at
        assert_equal 1, TreatmentPlanConcurrence.count
      end

      test "create refuses non-hash problems_goals entries without raising" do
        [ [ "anxiety" ], [ 1 ] ].each do |problems_goals|
          result = create_plan(problems_goals: problems_goals)

          refute result.success?, problems_goals.inspect
          assert_equal :invalid_plan, result.error
          assert_equal 0, TreatmentPlan.count
        end
      end

      test "progress review and create fail when program interval parts store string counts" do
        plan = create_plan.record
        due_before = plan.progress_review_due_on
        BehavioralHealthProgramConfiguration.for_program(PROGRAM).update_column(
          :progress_review_interval_parts,
          { "days" => "60" }
        )
        service = TreatmentPlanService.new(plan: plan)

        review_result = service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        )

        refute review_result.success?
        assert_equal :invalid_program_configuration, review_result.error
        plan.reload
        assert_equal 0, plan.progress_reviews.count
        assert_equal due_before, plan.progress_review_due_on

        create_result = create_plan
        refute create_result.success?
        assert_equal :invalid_program_configuration, create_result.error
        assert_equal 1, TreatmentPlan.count
      end

      test "record_progress_review refuses reviewed_on before date_established without storing a review" do
        plan = create_plan.record
        due_before = plan.progress_review_due_on
        service = TreatmentPlanService.new(plan: plan)

        result = service.record_progress_review(
          reviewed_on: Date.new(2025, 12, 31),
          reviewed_by_duz: PROVIDER
        )

        refute result.success?
        assert_equal :reviewed_before_established, result.error
        plan.reload
        assert_equal 0, plan.progress_reviews.count
        assert_equal due_before, plan.progress_review_due_on
      end

      test "create refuses date_established after the current date without raising" do
        travel_to Time.zone.parse("2026-06-01").middle_of_day do
          result = create_plan(date_established: Date.current + 1.day)

          refute result.success?
          assert_equal :invalid_plan, result.error
          assert_equal 0, TreatmentPlan.count
        end
      end
    end
  end
end
