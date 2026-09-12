# frozen_string_literal: true

module Lakeraven
  module EHR
    # Scores a screening instrument and records the result against an open
    # encounter.
    #
    # Three refusals, all before anything is written, and ALL of the ones that
    # apply are reported together (`Result#errors`) rather than the first one
    # found:
    #
    #   :missing_encounter  — a clinician administration has no visit context.
    #   :incomplete         — unanswered items; the caller gets the missing
    #                         link ids back and NO score is recorded.
    #   :safety_unacknowledged
    #                       — PHQ-9 item 9 (self-harm) is above "not at all"
    #                         and the caller has not acknowledged the safety
    #                         prompt. Clinical-safety gate, enforced HERE and
    #                         not in the view, so it holds for every caller —
    #                         the clinician form, the pre-visit link (#471) and
    #                         anything else that arrives later. It needs no
    #                         JavaScript: the caller re-presents the prompt and
    #                         resubmits with `safety_acknowledged`.
    #
    # The service takes plain arguments and reads no session, no current_user
    # and no request. That is the seam #471 needs: a tokenized pre-visit
    # submission is the same call with `source: "pre-visit"`.
    #
    # Recording is idempotent within a short window (see DEDUPE_WINDOW): a
    # double-tap or a back-button resubmit returns the administration that is
    # already there instead of trending the same screening twice.
    class ScreeningEntryService
      # Acknowledgement is CAST HERE, never trusted from the caller. Plain Ruby
      # truthiness accepts the strings "false" and "0", the integer 0, and any
      # array or hash — so `?safety_acknowledged=false` or the array param form
      # `safety_acknowledged[]=` would open a clinical-safety gate. The gate is
      # only opened by a SCALAR that casts to boolean true: a collection is
      # never an acknowledgement, whatever it contains.
      ACKNOWLEDGEMENT_TYPES = [ TrueClass, FalseClass, NilClass, String, Symbol, Integer ].freeze

      def self.acknowledged?(value)
        return false unless ACKNOWLEDGEMENT_TYPES.any? { |type| value.is_a?(type) }

        ActiveModel::Type::Boolean.new.cast(value) == true
      end

      # A refusal reports EVERY reason it refused, not the first one found:
      # `errors` is the full list, `error` the primary one (callers that only
      # branch on a single reason keep working). Fixing the visit number should
      # not be how a clinician discovers eight items are unanswered.
      Result = Struct.new(:success, :record, :score, :error, :errors, :missing_link_ids,
                          :safety_prompt_required, :duplicate, keyword_init: true) do
        def success? = success
        def safety_prompt_required? = !!safety_prompt_required
        def missing_link_ids = self[:missing_link_ids] || []
        def errors = self[:errors] || [ self[:error] ].compact
        # True when this administration already existed and was returned
        # unchanged rather than written again.
        def duplicate? = !!duplicate
      end

      def initialize(instrument:, patient_dfn:, answers:, encounter_ien: nil,
                     administered_by: nil, source: ScreeningResponse::SOURCE_CLINICIAN,
                     effective_at: nil, safety_acknowledged: false,
                     repository: ScreeningResponse)
        @instrument = instrument.is_a?(ScreeningInstrument) ? instrument : ScreeningInstrument.find!(instrument)
        @patient_dfn = patient_dfn
        @answers = answers
        @encounter_ien = encounter_ien
        @administered_by = administered_by
        @source = source.to_s
        @effective_at = effective_at
        @safety_acknowledged = self.class.acknowledged?(safety_acknowledged)
        @repository = repository
      end

      def save
        return failure(:invalid_input) if @patient_dfn.blank?
        return failure(:invalid_source) unless ScreeningResponse::SOURCES.include?(@source)

        score = @instrument.score(@answers)
        safety_required = score.safety_triggered? && !@safety_acknowledged

        reasons = []
        # A clinician records against the open visit. A pre-visit self-report
        # legitimately precedes one, so it is not held to that (#471).
        reasons << :missing_encounter if clinician? && @encounter_ien.blank?
        reasons << :incomplete unless score.complete?
        reasons << :safety_unacknowledged if safety_required

        if reasons.any?
          return failure(*reasons, score: score, missing_link_ids: score.missing_link_ids,
                                   safety_prompt_required: safety_required)
        end

        persist(score)
      end

      private

      def clinician? = @source == ScreeningResponse::SOURCE_CLINICIAN

      # A double-tap on a tablet, or a back-button resubmit, must not put two
      # administrations into the record — #483 would trend the same screening
      # twice. An administration is identified by (patient, instrument, visit,
      # effective window); the ANSWERS are part of the match because a
      # DIFFERENT set inside the window is a correction or a genuine second
      # administration, and silently discarding clinical data is worse than a
      # duplicate row.
      DEDUPE_WINDOW = 5.minutes

      def existing_administration(score, effective_at)
        return nil unless @repository.respond_to?(:where)

        @repository
          .where(patient_dfn: @patient_dfn, instrument_key: @instrument.key,
                 encounter_ien: @encounter_ien.presence)
          .where(effective_at: (effective_at - DEDUPE_WINDOW)..(effective_at + DEDUPE_WINDOW))
          .find { |candidate| candidate.ordinals == score.answers }
      end

      def persist(score)
        effective_at = @effective_at || Time.current
        existing = existing_administration(score, effective_at)
        return Result.new(success: true, record: existing, score: score, duplicate: true) if existing

        record = @repository.create!(
          patient_dfn: @patient_dfn,
          encounter_ien: @encounter_ien.presence,
          instrument_key: @instrument.key,
          answers: score.answers,
          total_score: score.total,
          severity_band: score.band,
          effective_at: effective_at,
          administered_by: @administered_by.presence,
          source: @source,
          safety_flagged: score.safety_triggered?,
          # A flagged row only reaches the table because someone acknowledged
          # the prompt: record WHEN and by WHOM, so a row from a clinician who
          # did the risk assessment is distinguishable from one that did not.
          # A pre-visit self-report (#471) has no DUZ; the timestamp still lands.
          safety_acknowledged_at: score.safety_triggered? ? Time.current : nil,
          safety_acknowledged_by: score.safety_triggered? ? @administered_by.presence : nil
        )

        Result.new(success: true, record: record, score: score)
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.warn("[screening] persist failed: #{e.class}")
        failure(:persistence_error, score: score)
      end

      def failure(*reasons, score: nil, missing_link_ids: nil, safety_prompt_required: false)
        Result.new(success: false, error: reasons.first, errors: reasons, score: score,
                   missing_link_ids: missing_link_ids,
                   safety_prompt_required: safety_prompt_required)
      end
    end
  end
end
