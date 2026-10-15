# frozen_string_literal: true

module Lakeraven
  module EHR
    # Visit-level psychotherapy coding stored against an existing encounter
    # (the visit IEN), not a parallel encounter record.
    #
    # `cpt_code` is derived. It is present only when the minutes and any
    # clinician selection agree, so a stored row can still be unbillable
    # (under 16 minutes, or a selection outside the band) and finalization
    # refuses those. Missing duration, non-positive duration, a code outside
    # the psychotherapy set, and a code from the wrong encounter kind are
    # not valid rows.
    #
    # The claim handoff carries the procedure code and the documented
    # duration only. Diagnosis stays on the POV / claim path (#560).
    class BehavioralHealthVisitCoding < ApplicationRecord
      self.table_name = "lakeraven_ehr_behavioral_health_visit_codings"

      KINDS = [
        PsychotherapyVisitCodingRules::ENCOUNTER_KIND_PSYCHIATRIC_DIAGNOSTIC_EVALUATION,
        PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY
      ].freeze

      before_validation :normalize_identifiers
      before_validation :assign_derived_cpt_code

      validates :patient_dfn, presence: true
      validates :encounter_ien, presence: true
      validates :documented_by_duz, presence: true
      validates :encounter_kind, inclusion: { in: KINDS }
      validate :hard_blocks_are_refused

      def resolved? = proposal.reportable?

      def blocking_reason = proposal.blocking_reason

      def finalize_blocked? = !resolved?

      # Procedure code plus duration. No diagnosis keys — those are a
      # different claim input and must not ride along on this handoff.
      def to_claim_procedure_handoff
        return nil unless resolved?

        {
          procedure_code: cpt_code,
          duration_minutes: duration_minutes,
          code_system: Procedure::CODE_SYSTEM_URLS["cpt"]
        }
      end

      private

      def proposal
        PsychotherapyVisitCodingRules.proposal(
          encounter_kind: encounter_kind,
          duration_minutes: duration_minutes,
          selected_cpt_code: selected_cpt_code
        )
      end

      def normalize_identifiers
        self.encounter_ien = strip_or_nil(encounter_ien)
        self.documented_by_duz = strip_or_nil(documented_by_duz)
        self.selected_cpt_code = strip_or_nil(selected_cpt_code)
      end

      def strip_or_nil(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def assign_derived_cpt_code
        self.cpt_code = proposal.reportable? ? proposal.cpt_code : nil
      end

      def hard_blocks_are_refused
        reason = blocking_reason
        return unless PsychotherapyVisitCodingRules::HARD_BLOCKS.include?(reason)

        errors.add(:base, reason.to_s)
      end
    end
  end
end
