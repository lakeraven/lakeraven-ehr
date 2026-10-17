# frozen_string_literal: true

module Lakeraven
  module EHR
    # A behavioral-health treatment plan held in the engine database.
    #
    # DIVERGENCE from RPMS: the legacy record is file 9002011.56. This one
    # is not. lakeraven-ehr#560 keeps therapy notes and treatment plans out
    # of shared RPMS files, so nothing here is reached through an RPC.
    #
    # progress_review_due_on is the compliance date. The plan is overdue only
    # when that date is already past — a review due today is still on time.
    # A plan with no due date is not on time either. Asking the instance
    # raises IndeterminateCompliance, and the overdue scope leaves the row
    # out, so a missing date cannot be counted as compliant. Those rows are
    # listed by progress_review_indeterminate. Absence of a due date is a
    # missing fact, not a pass.
    class TreatmentPlan < ApplicationRecord
      self.table_name = "lakeraven_ehr_treatment_plans"

      # Raised when a caller asks whether a plan is overdue and there is no
      # progress-review due date to compare. Returning false would publish
      # the plan as compliant.
      class IndeterminateCompliance < StandardError; end

      has_many :progress_reviews, dependent: :destroy,
               class_name: "Lakeraven::EHR::TreatmentPlanProgressReview",
               inverse_of: :treatment_plan
      has_one :concurrence, dependent: :destroy,
              class_name: "Lakeraven::EHR::TreatmentPlanConcurrence",
              inverse_of: :treatment_plan

      before_validation :stringify_problems_goals

      validates :patient_dfn, presence: true
      validates :program_key, presence: true
      validates :date_established, presence: true
      validates :designated_provider_duz, presence: true
      validates :narrative, presence: true
      validate :problems_goals_are_pairs

      # Due strictly before as_of. NULL fails the comparison, so a plan with
      # no due date is not in this relation. Same boundary as
      # #progress_review_overdue?: due today is on time, due yesterday is not.
      def self.progress_review_overdue(as_of: Date.current)
        where(progress_review_due_on: ...as_of)
      end

      def self.progress_review_indeterminate
        where(progress_review_due_on: nil)
      end

      def self.progress_review_overdue_count(as_of: Date.current)
        progress_review_overdue(as_of: as_of).count
      end

      def progress_review_overdue?(as_of: Date.current)
        raise IndeterminateCompliance if progress_review_due_on.nil?

        as_of > progress_review_due_on
      end

      # A VistA DUZ is an integer. "0301" and " 301" are the same provider as "301".
      def designated_provider?(duz)
        canonical_duz(duz) == canonical_duz(designated_provider_duz)
      end

      private

      def canonical_duz(duz)
        stripped = duz.to_s.strip
        stripped.match?(/\A\d+\z/) ? stripped.to_i.to_s : stripped
      end

      def stringify_problems_goals
        return unless problems_goals.is_a?(Array)

        self.problems_goals = problems_goals.map { |entry| problem_goal_hash(entry) || entry }
      end

      def problems_goals_are_pairs
        return if problem_goal_list?

        errors.add(:problems_goals, "must list each problem with its goal")
      end

      def problem_goal_list?
        problems_goals.is_a?(Array) && problems_goals.any? &&
          problems_goals.all? { |entry| problem_goal_pair?(entry) }
      end

      def problem_goal_pair?(entry)
        pair = problem_goal_hash(entry)
        return false unless pair

        pair["problem"].present? && pair["goal"].present?
      end

      # Only a Hash is a problem/goal pair. String#to_h and Array#to_h raise,
      # so a non-hash entry fails validation instead of escaping as an exception.
      def problem_goal_hash(entry)
        entry.stringify_keys if entry.is_a?(Hash)
      end
    end
  end
end
