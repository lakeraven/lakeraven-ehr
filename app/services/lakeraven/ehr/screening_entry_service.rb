# frozen_string_literal: true

module Lakeraven
  module EHR
    # Scores a screening instrument and records the result against an open
    # encounter.
    #
    # Three refusals, all before anything is written:
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

      Result = Struct.new(:success, :record, :score, :error, :missing_link_ids,
                          :safety_prompt_required, keyword_init: true) do
        def success? = success
        def safety_prompt_required? = !!safety_prompt_required
        def missing_link_ids = self[:missing_link_ids] || []
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

        # A clinician records against the open visit. A pre-visit self-report
        # legitimately precedes one, so it is not held to that (#471).
        if clinician? && @encounter_ien.blank?
          return failure(:missing_encounter, score: score, safety_prompt_required: safety_required)
        end

        unless score.complete?
          return failure(:incomplete, score: score, missing_link_ids: score.missing_link_ids,
                                      safety_prompt_required: safety_required)
        end

        if safety_required
          return failure(:safety_unacknowledged, score: score, safety_prompt_required: true)
        end

        persist(score)
      end

      private

      def clinician? = @source == ScreeningResponse::SOURCE_CLINICIAN

      def persist(score)
        record = @repository.create!(
          patient_dfn: @patient_dfn,
          encounter_ien: @encounter_ien.presence,
          instrument_key: @instrument.key,
          answers: score.answers,
          total_score: score.total,
          severity_band: score.band,
          effective_at: @effective_at || Time.current,
          administered_by: @administered_by.presence,
          source: @source,
          safety_flagged: score.safety_triggered?
        )

        Result.new(success: true, record: record, score: score)
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.warn("[screening] persist failed: #{e.class}")
        failure(:persistence_error, score: score)
      end

      def failure(reason, score: nil, missing_link_ids: nil, safety_prompt_required: false)
        Result.new(success: false, error: reason, score: score,
                   missing_link_ids: missing_link_ids,
                   safety_prompt_required: safety_prompt_required)
      end
    end
  end
end
