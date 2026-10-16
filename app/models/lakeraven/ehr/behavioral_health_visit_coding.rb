# frozen_string_literal: true

module Lakeraven
  module EHR
    # Visit-level psychotherapy coding stored against an existing encounter
    # (the visit IEN), not a parallel encounter record.
    #
    # `cpt_code` is derived. It is present only when the minutes and any
    # clinician selection agree, so a stored row can still be unbillable
    # (under 16 minutes, or a selection outside the band) and finalization
    # refuses those. Missing duration, a duration that is not a whole
    # number of minutes, non-positive duration, a code outside the
    # psychotherapy set, and a code from the wrong encounter kind are
    # not valid rows. The integer column casts "45junk" and 45.9 to 45,
    # so the supplied value is judged before that cast and before a code
    # is derived.
    #
    # The claim handoff carries the procedure code and the documented
    # duration only, and only when `cpt_code` is the code the minutes
    # derive now. That attribute is assigned in before_validation, so an
    # unvalidated row has none. A persisted row with any unsaved change
    # has no handoff: a same-band duration edit still matches the stored
    # code, and the other attributes are not part of that comparison.
    # Diagnosis stays on the POV / claim path (#560).
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
        # Any unsaved edit, not only duration. Same-band minutes still
        # match the stored CPT, so the code check never sees them.
        return nil if persisted? && changed?

        code = recorded_procedure_code
        return nil if code.nil?

        {
          procedure_code: code,
          duration_minutes: duration_minutes,
          code_system: Procedure::CODE_SYSTEM_URLS["cpt"]
        }
      end

      private

      # Stored by before_validation. Live `resolved?` is not enough: an
      # unsaved row and a row whose inputs have since changed would
      # otherwise hand off nil or the old code.
      def recorded_procedure_code
        return nil unless resolved?

        code = cpt_code
        return nil if code.nil? || code != proposal.cpt_code

        code
      end

      def proposal
        raw = duration_minutes_before_type_cast
        return invalid_duration_proposal unless whole_number_of_minutes?(raw)

        PsychotherapyVisitCodingRules.proposal(
          encounter_kind: encounter_kind,
          duration_minutes: raw.is_a?(String) ? raw.to_i : raw,
          selected_cpt_code: selected_cpt_code
        )
      end

      # Integer columns cast before a validation sees the attribute.
      # Only an Integer, or a string of digits, is a whole number of
      # minutes. nil is absence, which the rules name themselves.
      def whole_number_of_minutes?(raw)
        raw.nil? || raw.is_a?(Integer) || (raw.is_a?(String) && raw.match?(/\A\d+\z/))
      end

      def invalid_duration_proposal
        PsychotherapyVisitCodingRules::Proposal.new(
          cpt_code: nil,
          reportable: false,
          blocking_reason: :invalid_duration,
          duration_minutes: nil
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
