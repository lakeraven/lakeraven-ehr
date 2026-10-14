# frozen_string_literal: true

module Lakeraven
  module EHR
    # A behavioral-health treatment plan, with its documentation-compliance
    # cadence held as fields rather than prose: established date, the next
    # progress review due, an optional end-of-treatment review due, the
    # designated provider, and a concurring supervisor. Payer BH documentation
    # audits read exactly these dates, and the overdue worklist counts them.
    #
    # DIVERGENCE FLAG — this store is OUR design, not RPMS behavior. RPMS keeps
    # treatment plans in file 9002011.56, which sits beside the shared clinical
    # files and has no per-record sensitivity flag. Plan content written there
    # could not be pulled back under a later Part 2 boundary (#560), so the plan
    # lives in the engine's own database and is not written back to RPMS. Field
    # names follow this engine's vocabulary, not the FileMan field labels.
    #
    # The review cadence is a fixed 60 days here. Program-configurable
    # intervals belong to the access clock (#499).
    class TreatmentPlan < ApplicationRecord
      self.table_name = "lakeraven_ehr_treatment_plans"

      PROGRESS_REVIEW_INTERVAL = 60

      has_many :reviews, -> { order(:reviewed_on, :id) },
               class_name: "Lakeraven::EHR::TreatmentPlanReview",
               inverse_of: :treatment_plan,
               dependent: :restrict_with_exception

      before_validation :normalize_identifiers

      validates :patient_dfn, presence: true
      validates :established_on, presence: true
      validates :designated_provider, presence: true
      validates :progress_review_due_on, presence: true
      validate :dates_follow_establishment
      validate :concurrence_is_complete_and_by_another_clinician

      scope :not_ended, -> { where(ended_on: nil) }
      scope :for_patient, ->(dfn) { where(patient_dfn: dfn).order(:established_on, :id) }
      # Overdue means the due date has PASSED: a review due today is still on
      # time today.
      scope :reviews_overdue, lambda { |as_of: Date.current|
        not_ended.where(progress_review_due_on: ...as_of).order(:progress_review_due_on, :id)
      }

      # Creates a plan with its first progress-review due date computed from
      # the established date. The due date is never taken from the caller: the
      # computed value is passed last, so it wins over any supplied one.
      def self.establish!(established_on:, **attributes)
        create!(
          **attributes,
          established_on: established_on,
          progress_review_due_on: established_on && established_on + PROGRESS_REVIEW_INTERVAL
        )
      end

      # Documents a progress review and restarts the cadence from the latest
      # review on record. A review documented late with an earlier date is
      # kept in the history but does not pull the due date back.
      def record_progress_review!(reviewed_on:, reviewed_by:)
        transaction do
          lock!
          review = reviews.create!(reviewed_on: reviewed_on, reviewed_by: reviewed_by)
          latest = reviews.maximum(:reviewed_on)
          update!(progress_review_due_on: latest + PROGRESS_REVIEW_INTERVAL)
          review
        end
      end

      def concur!(supervisor:, at:)
        update!(concurring_supervisor: supervisor, supervisor_concurred_at: at)
      end

      def end!(on:)
        update!(ended_on: on)
      end

      def ended? = ended_on.present?

      def supervisor_concurred? = concurring_supervisor.present? && supervisor_concurred_at.present?

      def review_overdue?(as_of: Date.current) = !ended? && progress_review_due_on < as_of

      private

      def normalize_identifiers
        self.designated_provider = designated_provider.to_s.strip.presence
        self.concurring_supervisor = concurring_supervisor.to_s.strip.presence
      end

      def dates_follow_establishment
        return if established_on.nil?

        if progress_review_due_on && progress_review_due_on <= established_on
          errors.add(:progress_review_due_on, "must fall after the plan was established")
        end
        if end_of_treatment_review_due_on && end_of_treatment_review_due_on < established_on
          errors.add(:end_of_treatment_review_due_on, "cannot fall before the plan was established")
        end
        return unless ended_on && ended_on < established_on

        errors.add(:ended_on, "cannot fall before the plan was established")
      end

      def concurrence_is_complete_and_by_another_clinician
        return if concurring_supervisor.nil? && supervisor_concurred_at.nil?

        errors.add(:concurring_supervisor, "must be recorded with the concurrence") if concurring_supervisor.nil?
        errors.add(:supervisor_concurred_at, "must be recorded with the concurrence") if supervisor_concurred_at.nil?
        return unless concurring_supervisor.present? && concurring_supervisor == designated_provider

        errors.add(:concurring_supervisor, "must be a clinician other than the designated provider")
      end
    end
  end
end
