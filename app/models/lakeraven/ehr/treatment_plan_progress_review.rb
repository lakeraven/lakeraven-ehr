# frozen_string_literal: true

module Lakeraven
  module EHR
    # One progress review of a treatment plan: who reviewed it, and the date
    # the next due date is computed from. The due date itself lives on the
    # plan; this row is the evidence the review happened.
    class TreatmentPlanProgressReview < ApplicationRecord
      self.table_name = "lakeraven_ehr_treatment_plan_progress_reviews"

      belongs_to :treatment_plan, class_name: "Lakeraven::EHR::TreatmentPlan", inverse_of: :progress_reviews

      validates :reviewed_on, presence: true
      validates :reviewed_by_duz, presence: true
    end
  end
end
