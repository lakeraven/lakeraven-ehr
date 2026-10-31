# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class TreatmentPlanServiceReviewSafetyTest < ActiveSupport::TestCase
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

      test "creating a plan honours month-then-day interval after jsonb stores days before months" do
        program_key = "interval_order_plan_month_plus_day"
        BehavioralHealthProgramConfiguration.assign(
          program_key: program_key,
          progress_review_interval: 60.days,
          end_of_treatment_review_interval: 6.months
        )
        BehavioralHealthProgramConfiguration.for_program(program_key).update_column(
          :progress_review_interval_parts,
          { "days" => 1, "months" => 1 }
        )

        result = create_plan(
          program_key: program_key,
          date_established: Date.new(2026, 1, 30)
        )

        assert result.success?, result.error.inspect
        assert_equal Date.new(2026, 3, 1), result.record.progress_review_due_on
      end

      test "record_progress_review locks the treatment plan row before inserting the review" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)
        plan_table = TreatmentPlan.table_name
        locked = false

        callback = lambda do |_name, _start, _finish, _id, payload|
          sql = payload[:sql]
          next unless sql.match?(/FOR UPDATE/i)
          next unless sql.include?(plan_table)

          locked = true
        end

        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          result = service.record_progress_review(
            reviewed_on: Date.new(2026, 2, 1),
            reviewed_by_duz: PROVIDER
          )
          assert result.success?, result.error.inspect
        end

        assert locked, "expected SELECT ... FOR UPDATE on #{plan_table} during record_progress_review"
      end

      test "record_progress_review sets due date from the latest reviewed_on on file" do
        plan = create_plan.record
        service = TreatmentPlanService.new(plan: plan)

        assert service.record_progress_review(
          reviewed_on: Date.new(2026, 3, 20),
          reviewed_by_duz: PROVIDER
        ).success?

        assert service.record_progress_review(
          reviewed_on: Date.new(2026, 2, 10),
          reviewed_by_duz: PROVIDER
        ).success?

        plan.reload
        assert_equal Date.new(2026, 5, 19), plan.progress_review_due_on
        assert_equal 2, plan.progress_reviews.count
      end

      test "create with nil program_key returns unknown_program without raising" do
        result = TreatmentPlanService.new(
          patient_dfn: DFN,
          program_key: nil,
          date_established: Date.new(2026, 1, 1),
          designated_provider_duz: PROVIDER,
          narrative: "Synthetic narrative.",
          problems_goals: [ { problem: "Example problem", goal: "Example goal" } ]
        ).create

        refute result.success?
        assert_equal :unknown_program, result.error
        assert_equal 0, TreatmentPlan.count
      end

      test "create with blank program_key returns unknown_program without raising" do
        result = TreatmentPlanService.new(
          patient_dfn: DFN,
          program_key: "",
          date_established: Date.new(2026, 1, 1),
          designated_provider_duz: PROVIDER,
          narrative: "Synthetic narrative.",
          problems_goals: [ { problem: "Example problem", goal: "Example goal" } ]
        ).create

        refute result.success?
        assert_equal :unknown_program, result.error
        assert_equal 0, TreatmentPlan.count
      end
    end
  end
end
