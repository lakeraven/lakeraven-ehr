# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanServiceReviewDateNormalizationTest < ActiveSupport::TestCase
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

      test "create returns invalid_program_configuration when progress interval parts are a string" do
        BehavioralHealthProgramConfiguration.for_program(PROGRAM).update_column(
          :progress_review_interval_parts,
          "60"
        )

        result = create_plan

        refute result.success?
        assert_equal :invalid_program_configuration, result.error
        assert_equal 0, TreatmentPlan.count
      end

      test "create returns invalid_program_configuration when progress interval parts are an array" do
        BehavioralHealthProgramConfiguration.for_program(PROGRAM).update_column(
          :progress_review_interval_parts,
          [ 60 ]
        )

        result = create_plan

        refute result.success?
        assert_equal :invalid_program_configuration, result.error
        assert_equal 0, TreatmentPlan.count
      end

      test "create returns invalid_program_configuration when end of treatment interval parts are a string" do
        BehavioralHealthProgramConfiguration.for_program(PROGRAM).update_column(
          :end_of_treatment_review_interval_parts,
          "60"
        )

        result = create_plan

        refute result.success?
        assert_equal :invalid_program_configuration, result.error
        assert_equal 0, TreatmentPlan.count
      end

      test "create returns invalid_program_configuration when end of treatment interval parts are an array" do
        BehavioralHealthProgramConfiguration.for_program(PROGRAM).update_column(
          :end_of_treatment_review_interval_parts,
          [ 60 ]
        )

        result = create_plan

        refute result.success?
        assert_equal :invalid_program_configuration, result.error
        assert_equal 0, TreatmentPlan.count
      end

      test "record_progress_review returns invalid_program_configuration when progress parts become a string" do
        plan = create_plan.record
        due_before = plan.progress_review_due_on
        BehavioralHealthProgramConfiguration.for_program(PROGRAM).update_column(
          :progress_review_interval_parts,
          "60"
        )
        service = TreatmentPlanService.new(plan: plan)

        result = service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        )

        refute result.success?
        assert_equal :invalid_program_configuration, result.error
        plan.reload
        assert_equal 0, plan.progress_reviews.count
        assert_equal due_before, plan.progress_review_due_on
      end

      test "record_progress_review returns invalid_program_configuration when progress parts become an array" do
        plan = create_plan.record
        due_before = plan.progress_review_due_on
        BehavioralHealthProgramConfiguration.for_program(PROGRAM).update_column(
          :progress_review_interval_parts,
          [ 60 ]
        )
        service = TreatmentPlanService.new(plan: plan)

        result = service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 1),
          reviewed_by_duz: PROVIDER
        )

        refute result.success?
        assert_equal :invalid_program_configuration, result.error
        plan.reload
        assert_equal 0, plan.progress_reviews.count
        assert_equal due_before, plan.progress_review_due_on
      end

      test "record_progress_review accepts DateTime on today and stores a calendar date" do
        travel_to Time.zone.local(2026, 10, 16, 9, 0) do
          plan = create_plan.record
          service = TreatmentPlanService.new(plan: plan)
          reviewed_at = DateTime.new(2026, 10, 16, 12, 0)

          result = service.record_progress_review(
            reviewed_on: reviewed_at,
            reviewed_by_duz: PROVIDER
          )

          assert result.success?, result.error.inspect
          review = plan.progress_reviews.first
          assert_equal Date.new(2026, 10, 16), review.reviewed_on
          assert_instance_of Date, review.reviewed_on
          assert_not_instance_of DateTime, review.reviewed_on
          plan.reload
          assert_equal Date.new(2026, 12, 15), plan.progress_review_due_on
        end
      end

      test "record_progress_review refuses DateTime after midnight tomorrow as reviewed_on_in_future" do
        travel_to Time.zone.local(2026, 10, 16, 9, 0) do
          plan = create_plan.record
          due_before = plan.progress_review_due_on
          service = TreatmentPlanService.new(plan: plan)

          result = service.record_progress_review(
            reviewed_on: DateTime.new(2026, 10, 17, 0, 30),
            reviewed_by_duz: PROVIDER
          )

          refute result.success?
          assert_equal :reviewed_on_in_future, result.error
          plan.reload
          assert_equal 0, plan.progress_reviews.count
          assert_equal due_before, plan.progress_review_due_on
        end
      end

      test "create accepts DateTime on today and stores date_established as a calendar date" do
        travel_to Time.zone.local(2026, 10, 16, 9, 0) do
          result = create_plan(date_established: DateTime.new(2026, 10, 16, 12, 0))

          assert result.success?, result.error.inspect
          plan = result.record
          assert_equal Date.new(2026, 10, 16), plan.date_established
          assert_instance_of Date, plan.date_established
          assert_not_instance_of DateTime, plan.date_established
        end
      end
    end
  end
end
