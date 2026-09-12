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

      # Recording is IDEMPOTENT, and the dedupe rule lives in the model as the
      # administration's identity (ScreeningResponse.administration_digest_for)
      # with a UNIQUE INDEX behind it. This service does not keep a second,
      # slightly different rule of its own: it looks the administration up,
      # inserts if it is not there, and treats a unique violation — the lost
      # side of a race — as the same duplicate answer rather than an error.
      def existing_administration(digest)
        return nil unless @repository.respond_to?(:find_by)

        @repository.find_by(administration_digest: digest)
      end

      def normalized_encounter_ien = @encounter_ien.to_s.strip.presence

      def administration_digest(score, effective_at)
        ScreeningResponse.administration_digest_for(
          patient_dfn: @patient_dfn, instrument_key: @instrument.key,
          encounter_ien: normalized_encounter_ien, administered_by: @administered_by.presence,
          answers: score.answers, effective_at: effective_at
        )
      end

      def persist(score)
        effective_at = @effective_at || Time.current
        digest = administration_digest(score, effective_at)

        duplicate = duplicate_result(existing_administration(digest), score)
        return duplicate if duplicate

        insert(score, effective_at)
      rescue ActiveRecord::RecordNotUnique
        # The lost side of a race: the winner's row is now there. Returning it
        # is the idempotent answer — the same one the caller would have got had
        # it arrived a millisecond later.
        duplicate_result(existing_administration(digest), score) ||
          failure(:conflicting_record, score: score)
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.warn("[screening] persist failed: #{e.class}")
        failure(:persistence_error, score: score)
      end

      # An existing administration is only handed back as a duplicate if it is
      # PUBLISHABLE. A row that fails its own invariants (written around the
      # model, restored, imported) is not a prior administration, and returning
      # it would launder it into the clinical record as if a clinician had just
      # confirmed it. It also cannot simply be written over, so this fails
      # closed and names the reason rather than silently doing either.
      def duplicate_result(existing, score)
        return nil if existing.nil?

        unless existing.publishable?
          Rails.logger.warn("[screening] conflicting unpublishable row #{existing.id}")
          return failure(:conflicting_record, score: score)
        end

        Result.new(success: true, record: existing, score: score, duplicate: true)
      end

      def insert(score, effective_at)
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
