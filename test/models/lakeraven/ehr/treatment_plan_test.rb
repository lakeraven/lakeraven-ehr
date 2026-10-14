# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The plan's review-due date is what an auditor reads and what the overdue
    # worklist counts, so it must always be present, always follow from the
    # plan's own history, and never be movable into the past or the future by
    # a stray write.
    class TreatmentPlanTest < ActiveSupport::TestCase
      THERAPIST = "99999"
      SUPERVISOR = "77777"

      teardown do
        TreatmentPlanReview.delete_all
        TreatmentPlan.delete_all
      end

      def establish(**overrides)
        TreatmentPlan.establish!(
          patient_dfn: 123,
          established_on: Date.new(2026, 10, 1),
          designated_provider: THERAPIST,
          **overrides
        )
      end

      # -- Establishing ------------------------------------------------------

      test "establishing a plan stores a progress review due 60 days out" do
        plan = establish
        assert_equal Date.new(2026, 11, 30), plan.reload.progress_review_due_on
      end

      test "the due date is computed, not taken from the caller" do
        plan = establish(progress_review_due_on: Date.new(2030, 1, 1))
        assert_equal Date.new(2026, 11, 30), plan.reload.progress_review_due_on
      end

      test "a plan requires a patient, an established date and a designated provider" do
        %i[patient_dfn established_on designated_provider].each do |attribute|
          error = assert_raises(ActiveRecord::RecordInvalid) { establish(attribute => nil) }
          assert error.record.errors.key?(attribute), "#{attribute}: #{error.record.errors.full_messages.inspect}"
        end
      end

      test "a blank designated provider is no provider" do
        error = assert_raises(ActiveRecord::RecordInvalid) { establish(designated_provider: "  ") }
        assert error.record.errors.key?(:designated_provider)
      end

      test "the database refuses a plan with no progress review due date" do
        # A plan with no due date could never be overdue: absence of data must
        # not read as compliance, whatever wrote the row.
        plan = establish
        assert_raises(ActiveRecord::NotNullViolation) do
          plan.update_column(:progress_review_due_on, nil)
        end
      end

      test "an end-of-treatment review due date is optional and recordable" do
        plan = establish
        assert_nil plan.end_of_treatment_review_due_on
        plan.update!(end_of_treatment_review_due_on: Date.new(2027, 4, 1))
        assert_equal Date.new(2027, 4, 1), plan.reload.end_of_treatment_review_due_on
      end

      test "an end-of-treatment review cannot fall due before the plan was established" do
        plan = establish
        assert_not plan.update(end_of_treatment_review_due_on: Date.new(2026, 9, 30))
        assert plan.errors.key?(:end_of_treatment_review_due_on)
      end

      # -- Supervisor concurrence -------------------------------------------

      test "concurrence stores who and when" do
        plan = establish
        at = Time.utc(2026, 10, 2, 9, 30)
        plan.concur!(supervisor: SUPERVISOR, at: at)
        plan.reload
        assert_equal SUPERVISOR, plan.concurring_supervisor
        assert_equal at.to_i, plan.supervisor_concurred_at.to_i
        assert plan.supervisor_concurred?
      end

      test "the designated provider cannot concur with their own plan" do
        plan = establish
        assert_raises(ActiveRecord::RecordInvalid) { plan.concur!(supervisor: THERAPIST, at: Time.current) }
        assert_nil plan.reload.concurring_supervisor
      end

      test "concurrence needs both who and when" do
        plan = establish
        assert_raises(ActiveRecord::RecordInvalid) { plan.concur!(supervisor: SUPERVISOR, at: nil) }
        assert_raises(ActiveRecord::RecordInvalid) { plan.concur!(supervisor: nil, at: Time.current) }
      end

      test "the database refuses half a concurrence and self-concurrence" do
        plan = establish
        assert_raises(ActiveRecord::StatementInvalid) do
          plan.update_columns(concurring_supervisor: SUPERVISOR, supervisor_concurred_at: nil)
        end
        assert_raises(ActiveRecord::StatementInvalid) do
          plan.update_columns(concurring_supervisor: THERAPIST, supervisor_concurred_at: Time.current)
        end
      end

      # -- Progress review --------------------------------------------------

      test "documenting a review recomputes the next due date from the review date" do
        plan = establish
        plan.record_progress_review!(reviewed_on: Date.new(2026, 11, 20), reviewed_by: THERAPIST)
        assert_equal Date.new(2027, 1, 19), plan.reload.progress_review_due_on
        assert_equal [ Date.new(2026, 11, 20) ], plan.reviews.map(&:reviewed_on)
      end

      test "a back-dated review never pulls the due date earlier than a later review set it" do
        plan = establish
        plan.record_progress_review!(reviewed_on: Date.new(2026, 11, 20), reviewed_by: THERAPIST)
        plan.record_progress_review!(reviewed_on: Date.new(2026, 11, 1), reviewed_by: THERAPIST)
        assert_equal Date.new(2027, 1, 19), plan.reload.progress_review_due_on
        assert_equal 2, plan.reviews.count
      end

      test "a review must name who performed it" do
        plan = establish
        assert_raises(ActiveRecord::RecordInvalid) do
          plan.record_progress_review!(reviewed_on: Date.new(2026, 11, 20), reviewed_by: nil)
        end
        assert_equal Date.new(2026, 11, 30), plan.reload.progress_review_due_on
      end

      test "a review cannot predate the plan" do
        plan = establish
        assert_raises(ActiveRecord::RecordInvalid) do
          plan.record_progress_review!(reviewed_on: Date.new(2026, 9, 30), reviewed_by: THERAPIST)
        end
        assert_equal 0, plan.reviews.count
      end

      test "a review cannot be dated in the future" do
        # A future-dated review would push the due date out and hide a plan
        # from the overdue worklist before any review happened.
        plan = establish(established_on: Date.current - 10)
        assert_raises(ActiveRecord::RecordInvalid) do
          plan.record_progress_review!(reviewed_on: Date.current + 1, reviewed_by: THERAPIST)
        end
        assert_equal 0, plan.reviews.count
      end

      test "an ended plan takes no further reviews" do
        plan = establish
        plan.end!(on: Date.new(2026, 11, 15))
        assert_raises(ActiveRecord::RecordInvalid) do
          plan.record_progress_review!(reviewed_on: Date.new(2026, 11, 20), reviewed_by: THERAPIST)
        end
      end

      test "a plan cannot end before it was established" do
        plan = establish
        assert_raises(ActiveRecord::RecordInvalid) { plan.end!(on: Date.new(2026, 9, 1)) }
        assert_nil plan.reload.ended_on
      end

      # -- Overdue ----------------------------------------------------------

      test "a plan is overdue the day after its review falls due" do
        plan = establish
        assert_not_includes TreatmentPlan.reviews_overdue(as_of: Date.new(2026, 11, 30)), plan
        assert_includes TreatmentPlan.reviews_overdue(as_of: Date.new(2026, 12, 1)), plan
      end

      test "an ended plan is never overdue" do
        plan = establish
        plan.end!(on: Date.new(2026, 11, 15))
        assert_not_includes TreatmentPlan.reviews_overdue(as_of: Date.new(2027, 1, 1)), plan
      end

      test "overdue is answered for a given day, defaulting to today" do
        plan = establish(established_on: Date.current - 61)
        assert_includes TreatmentPlan.reviews_overdue, plan
      end
    end
  end
end
