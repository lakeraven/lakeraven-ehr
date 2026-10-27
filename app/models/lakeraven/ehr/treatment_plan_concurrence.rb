# frozen_string_literal: true

module Lakeraven
  module EHR
    # A supervisor's concurrence with a treatment plan: who, and when.
    #
    # The designated provider cannot concur with their own plan. The service
    # refuses that call; this validation is the same rule for any other
    # writer. One plan has one concurrence.
    class TreatmentPlanConcurrence < ApplicationRecord
      self.table_name = "lakeraven_ehr_treatment_plan_concurrences"

      belongs_to :treatment_plan, class_name: "Lakeraven::EHR::TreatmentPlan", inverse_of: :concurrence

      validates :supervisor_duz, presence: true
      validates :concurred_at, presence: true
      validate :supervisor_is_not_the_designated_provider

      private

      def supervisor_is_not_the_designated_provider
        return unless treatment_plan&.designated_provider?(supervisor_duz)

        errors.add(:supervisor_duz, "is the designated provider")
      end
    end
  end
end
