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
    # Recording is idempotent on the SUBMISSION, not on the clinical content:
    # a caller that passes the `submission_token` of a submission already
    # recorded gets that administration back rather than a second one, while an
    # instrument genuinely re-administered later the same day is a new
    # submission and lands. See ScreeningResponse#submission_token.
    class ScreeningEntryService
      # An ALLOWLIST, not a cast. This gate was wrong three review rounds
      # running — raw truthiness, then the string `"false"`, then any string at
      # all — because each fix rejected the bad values someone had thought of.
      # `ActiveModel::Type::Boolean` returns false only for its own fixed falsy
      # set (`false, 0, "0", "f", "false", "off", ""`), so `banana`, `no`,
      # `null` and `-1` all cast TRUE and would persist a self-harm disclosure
      # as acknowledged.
      #
      # So: nothing is cast, coerced, downcased or stripped. Exactly these
      # three values acknowledge; EVERYTHING else — including values that
      # happen to cast true — does not. The checkbox posts `"1"`; a
      # programmatic caller (the pre-visit link, #471) passes `true`.
      ACKNOWLEDGEMENT_VALUES = [ true, "true", "1" ].freeze

      def self.acknowledged?(value)
        ACKNOWLEDGEMENT_VALUES.any? { |allowed| allowed.eql?(value) }
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
                     submission_token: nil, repository: ScreeningResponse)
        @instrument = instrument.is_a?(ScreeningInstrument) ? instrument : ScreeningInstrument.find!(instrument)
        @patient_dfn = patient_dfn
        @answers = answers
        @encounter_ien = encounter_ien
        @administered_by = administered_by
        @source = source.to_s
        @effective_at = effective_at
        @safety_acknowledged = self.class.acknowledged?(safety_acknowledged)
        @submission_token = submission_token.presence
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
        # An acknowledgement is a clinical act by a named person. A clinician
        # administration carrying a self-harm disclosure with no DUZ has no
        # one standing behind the risk assessment, which is the whole point of
        # the trace. (A pre-visit self-report, #471, has no clinician by
        # definition and is not held to this.)
        if score.safety_triggered? && clinician? && @administered_by.blank?
          reasons << :missing_administered_by
        end

        if reasons.any?
          return failure(*reasons, score: score, missing_link_ids: score.missing_link_ids,
                                   safety_prompt_required: safety_required)
        end

        persist(score)
      end

      private

      def clinician? = @source == ScreeningResponse::SOURCE_CLINICIAN

      # Recording is IDEMPOTENT ON THE SUBMISSION. The token identifies the
      # submission; a unique index on it makes one submission at most one
      # administration and settles the race that a check-then-insert cannot.
      # A caller with no token is not deduplicated at all — see the note on
      # ScreeningResponse#submission_token for why that is deliberate rather
      # than a gap.
      def existing_submission
        return nil if @submission_token.blank?
        return nil unless @repository.respond_to?(:find_by)

        @repository.find_by(submission_token: @submission_token)
      end

      def normalized_encounter_ien = @encounter_ien.to_s.strip.presence

      def persist(score)
        effective_at = @effective_at || Time.current

        duplicate = duplicate_result(existing_submission, score)
        return duplicate if duplicate

        insert(score, effective_at)
      rescue ActiveRecord::RecordNotUnique
        # The lost side of a race: the winner's row is now there. Returning it
        # is the idempotent answer — the same one the caller would have got had
        # it arrived a millisecond later.
        duplicate_result(existing_submission, score) ||
          failure(:conflicting_record, score: score)
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.warn("[screening] persist failed: #{e.class}")
        failure(:persistence_error, score: score)
      end

      # What an already-used token means depends on what is behind it:
      #
      #   * the SAME submission (same patient, instrument and answers) — this
      #     is the retry the token exists for, so return that row;
      #   * DIFFERENT answers, or another patient's or instrument's row — this
      #     is not a retry. A corrected form resubmitted under its original
      #     token is a new intent, and a token from elsewhere is not a key to
      #     anything. Refuse and name it rather than returning a record the
      #     caller did not just produce;
      #   * a row that fails its own invariants — never handed back, or a row
      #     written around the model would launder itself into the clinical
      #     record as though a clinician had just confirmed it.
      def duplicate_result(existing, score)
        return nil if existing.nil?

        unless existing.publishable?
          Rails.logger.warn("[screening] conflicting unpublishable row #{existing.id}")
          return failure(:conflicting_record, score: score)
        end

        return failure(:already_submitted, score: score) unless same_submission?(existing, score)

        Result.new(success: true, record: existing, score: score, duplicate: true)
      end

      def same_submission?(existing, score)
        existing.patient_dfn.to_s == @patient_dfn.to_s &&
          existing.instrument_key == @instrument.key &&
          existing.ordinals == score.answers
      end

      # The insert gets its own SAVEPOINT so that losing the unique-index race
      # is recoverable. Without it, a RecordNotUnique inside an enclosing
      # transaction (the controller now wraps every action in one) aborts that
      # whole transaction, and the recovery below would raise instead of
      # returning the winner's row.
      def insert(score, effective_at)
        @repository.transaction(requires_new: true) { insert!(score, effective_at) }
      end

      def insert!(score, effective_at)
        record = @repository.create!(
          patient_dfn: @patient_dfn,
          encounter_ien: normalized_encounter_ien,
          instrument_key: @instrument.key,
          answers: score.answers,
          total_score: score.total,
          severity_band: score.band,
          effective_at: effective_at,
          administered_by: @administered_by.presence,
          source: @source,
          submission_token: @submission_token,
          safety_flagged: score.safety_triggered?,
          # A flagged row only reaches the table because someone acknowledged
          # the prompt: record WHEN and by WHOM, so a row from a clinician who
          # did the risk assessment is distinguishable from one that did not.
          # A pre-visit self-report (#471) has no DUZ; the timestamp still lands.
          safety_acknowledged_at: score.safety_triggered? ? Time.current : nil,
          safety_acknowledged_by: score.safety_triggered? ? @administered_by.presence : nil
        )

        Result.new(success: true, record: record, score: score)
      end

      def failure(*reasons, score: nil, missing_link_ids: nil, safety_prompt_required: false)
        Result.new(success: false, error: reasons.first, errors: reasons, score: score,
                   missing_link_ids: missing_link_ids,
                   safety_prompt_required: safety_prompt_required)
      end
    end
  end
end
