# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanServiceProgramKeyMismatchTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      PROGRAM = "bh_outpatient"
      OTHER = "bh_intensive"
      DFN = 1
      PROVIDER = "301"
      SUPERVISOR = "401"
      REVIEWED_ON = Date.new(2026, 2, 1)
      EXPECTED_DUE_AFTER_REVIEW = Date.new(2026, 4, 2)

      setup do
        BehavioralHealthProgramConfiguration.reset!
        BehavioralHealthProgramConfiguration.assign(
          program_key: PROGRAM,
          progress_review_interval: 60.days,
          end_of_treatment_review_interval: 6.months
        )
        BehavioralHealthProgramConfiguration.assign(
          program_key: OTHER,
          progress_review_interval: 90.days,
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

      test "record_progress_review refuses a program_key that disagrees with the plan's program" do
        plan = create_plan.record
        due_before = plan.progress_review_due_on
        program_before = plan.program_key

        result = TreatmentPlanService.new(plan: plan, program_key: OTHER).record_progress_review(
          reviewed_on: REVIEWED_ON,
          reviewed_by_duz: PROVIDER
        )

        refute result.success?
        assert_equal :program_mismatch, result.error
        plan.reload
        assert_equal 0, plan.progress_reviews.count
        assert_equal due_before, plan.progress_review_due_on
        assert_equal program_before, plan.program_key
        assert_equal PROGRAM, plan.program_key
      end

      test "record_progress_review refuses a mismatched program_key given as a Symbol" do
        plan = create_plan.record
        due_before = plan.progress_review_due_on
        program_before = plan.program_key

        result = TreatmentPlanService.new(plan: plan, program_key: :bh_intensive).record_progress_review(
          reviewed_on: REVIEWED_ON,
          reviewed_by_duz: PROVIDER
        )

        refute result.success?
        assert_equal :program_mismatch, result.error
        plan.reload
        assert_equal 0, plan.progress_reviews.count
        assert_equal due_before, plan.progress_review_due_on
        assert_equal program_before, plan.program_key
      end

      test "record_progress_review succeeds when an explicit program_key matches the plan" do
        [ "bh_outpatient", :bh_outpatient ].each do |explicit_key|
          plan = create_plan.record
          service = TreatmentPlanService.new(plan: plan, program_key: explicit_key)

          result = service.record_progress_review(
            reviewed_on: REVIEWED_ON,
            reviewed_by_duz: PROVIDER
          )

          assert result.success?, "#{explicit_key.inspect}: #{result.error.inspect}"
          plan.reload
          assert_equal 1, plan.progress_reviews.count
          assert_equal EXPECTED_DUE_AFTER_REVIEW, plan.progress_review_due_on
          assert_equal PROGRAM, plan.program_key
        end
      end

      test "record_progress_review treats nil or blank program_key as the plan's program" do
        [ nil, "" ].each do |explicit_key|
          plan = create_plan.record
          service = TreatmentPlanService.new(plan: plan, program_key: explicit_key)

          result = service.record_progress_review(
            reviewed_on: REVIEWED_ON,
            reviewed_by_duz: PROVIDER
          )

          assert result.success?, "#{explicit_key.inspect}: #{result.error.inspect}"
          plan.reload
          assert_equal 1, plan.progress_reviews.count
          assert_equal EXPECTED_DUE_AFTER_REVIEW, plan.progress_review_due_on
          assert_equal PROGRAM, plan.program_key
        end
      end

      test "record_concurrence refuses a program_key that disagrees with the plan's program" do
        plan = create_plan.record
        program_before = plan.program_key
        concurred_at = Time.zone.local(2026, 2, 1, 10)

        result = TreatmentPlanService.new(plan: plan, program_key: OTHER).record_concurrence(
          supervisor_duz: SUPERVISOR,
          concurred_at: concurred_at
        )

        refute result.success?
        assert_equal :program_mismatch, result.error
        plan.reload
        assert_nil plan.concurrence
        assert_equal 0, TreatmentPlanConcurrence.count
        assert_equal program_before, plan.program_key
        assert_equal PROGRAM, plan.program_key
      end
    end
  end
end
