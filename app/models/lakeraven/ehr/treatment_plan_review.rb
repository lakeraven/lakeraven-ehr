# frozen_string_literal: true

module Lakeraven
  module EHR
    # One documented progress review of a treatment plan. Kept as a history
    # rather than a single "last reviewed" field, because an audit asks for
    # every review, not only the latest.
    class TreatmentPlanReview < ApplicationRecord
      self.table_name = "lakeraven_ehr_treatment_plan_reviews"

      belongs_to :treatment_plan, class_name: "Lakeraven::EHR::TreatmentPlan", inverse_of: :reviews

      before_validation { self.reviewed_by = reviewed_by.to_s.strip.presence }

      validates :reviewed_on, presence: true
      validates :reviewed_by, presence: true
      validate :reviewed_within_the_plan

      private

      # A future-dated review would push the due date out and take the plan
      # off the overdue worklist before any review happened.
      def reviewed_within_the_plan
        return if reviewed_on.nil? || treatment_plan.nil?

        errors.add(:reviewed_on, "cannot be in the future") if reviewed_on > Date.current
        if reviewed_on < treatment_plan.established_on
          errors.add(:reviewed_on, "cannot fall before the plan was established")
        end
        return unless treatment_plan.ended_on && reviewed_on > treatment_plan.ended_on

        errors.add(:reviewed_on, "cannot fall after the plan ended")
      end
    end
  end
end
