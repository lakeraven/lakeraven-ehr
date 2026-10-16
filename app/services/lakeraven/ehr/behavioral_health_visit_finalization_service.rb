# frozen_string_literal: true

module Lakeraven
  module EHR
    # Finishes a behavioral-health encounter only when its visit coding is
    # resolved, saved, and for this encounter. The refusal lives here, on
    # the encounter the rest of the chart already uses — not in a view,
    # and not on a second encounter type.
    #
    # Close only refuses a visit that is already finished, so a cancelled
    # or entered-in-error encounter is refused here — calling close would
    # record it as finished. The coding decision is then made on the stored
    # row under a row lock, not the caller's copy, and the lock is held
    # through close.
    class BehavioralHealthVisitFinalizationService
      Result = Struct.new(:success, :error, keyword_init: true) do
        def success? = !!success
      end

      # Attributes the caller saw. A stored row that resolved to different
      # values is not the coding this finalization was asked to accept.
      CODING_ATTRIBUTES = %i[
        duration_minutes
        selected_cpt_code
        encounter_kind
        encounter_ien
        patient_dfn
        documented_by_duz
      ].freeze

      TERMINAL_STATUSES = %w[cancelled entered-in-error].freeze

      def initialize(encounter:, visit_coding:)
        @encounter = encounter
        @visit_coding = visit_coding
      end

      def finalize
        reason = refusal
        return failure(reason) if reason

        Result.new(success: true)
      end

      private

      def refusal
        terminal_refusal || in_memory_refusal || stored_refusal
      end

      def terminal_refusal
        :encounter_not_closable if TERMINAL_STATUSES.include?(@encounter.status)
      end

      # Nil and unsaved local edits are refused on the caller's instance,
      # before the stored row is read. An unsaved edit makes the claim
      # handoff nil, and that refusal stays :coding_unresolved — ahead of
      # the stale comparison, which would otherwise see a different row.
      def in_memory_refusal
        return :coding_missing if @visit_coding.nil?
        return :coding_unresolved unless @visit_coding.resolved?
        return :coding_not_recorded unless @visit_coding.persisted?

        :coding_unresolved if @visit_coding.to_claim_procedure_handoff.nil?
      end

      def stored_refusal
        BehavioralHealthVisitCoding.transaction do
          stored = BehavioralHealthVisitCoding.lock.find_by(id: @visit_coding.id)
          refusal = stored_row_refusal(stored)
          refusal.nil? ? close_refusal : refusal
        end
      end

      def stored_row_refusal(stored)
        return :coding_not_recorded if stored.nil?
        return :coding_unresolved unless stored.resolved?
        return :coding_stale if coding_stale?(stored)
        return :coding_encounter_mismatch unless coding_matches_encounter?(stored)

        :coding_unresolved if stored.to_claim_procedure_handoff.nil?
      end

      def coding_stale?(stored)
        CODING_ATTRIBUTES.any? { |name| stored[name] != @visit_coding[name] }
      end

      def close_refusal
        :encounter_not_closable unless @encounter.close
      end

      def coding_matches_encounter?(coding)
        visit_ien_matches?(coding) && visit_patient_matches?(coding)
      end

      def visit_ien_matches?(coding)
        visit_ien = @encounter.ien
        return false if visit_ien.nil?

        coding.encounter_ien.to_s == visit_ien.to_s
      end

      # A visit with no patient_dfn is not this coding's patient. Missing
      # data must not let another patient's row finalize on the same IEN.
      def visit_patient_matches?(coding)
        visit_dfn = @encounter.patient_dfn
        return false if visit_dfn.nil?

        coding.patient_dfn.to_i == visit_dfn.to_i
      end

      def failure(reason)
        Result.new(success: false, error: reason)
      end
    end
  end
end
