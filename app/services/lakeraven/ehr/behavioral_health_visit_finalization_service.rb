# frozen_string_literal: true

module Lakeraven
  module EHR
    # Finishes a behavioral-health encounter only when its visit coding is
    # resolved, saved, and for this encounter. The refusal lives here, on
    # the encounter the rest of the chart already uses — not in a view,
    # and not on a second encounter type.
    class BehavioralHealthVisitFinalizationService
      Result = Struct.new(:success, :error, keyword_init: true) do
        def success? = !!success
      end

      def initialize(encounter:, visit_coding:)
        @encounter = encounter
        @visit_coding = visit_coding
      end

      def finalize
        return failure(:coding_missing) if @visit_coding.nil?
        return failure(:coding_unresolved) unless @visit_coding.resolved?
        return failure(:coding_not_recorded) unless @visit_coding.persisted?
        return failure(:coding_encounter_mismatch) unless coding_matches_encounter?
        return failure(:coding_unresolved) if @visit_coding.to_claim_procedure_handoff.nil?
        return failure(:encounter_not_closable) unless @encounter.close

        Result.new(success: true)
      end

      private

      def coding_matches_encounter?
        visit_ien_matches? && visit_patient_matches?
      end

      def visit_ien_matches?
        visit_ien = @encounter.ien
        return false if visit_ien.nil?

        @visit_coding.encounter_ien.to_s == visit_ien.to_s
      end

      # Encounters identified only by visit IEN carry no patient_dfn.
      # When the encounter has one, it has to be the coding's patient.
      def visit_patient_matches?
        visit_dfn = @encounter.patient_dfn
        return true if visit_dfn.nil?

        @visit_coding.patient_dfn.to_i == visit_dfn.to_i
      end

      def failure(reason)
        Result.new(success: false, error: reason)
      end
    end
  end
end
