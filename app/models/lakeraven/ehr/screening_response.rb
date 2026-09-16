# frozen_string_literal: true

module Lakeraven
  module EHR
    # A completed, scored administration of a screening instrument.
    #
    # Stored in the engine's own database rather than behind a gateway: RPMS
    # exposes no RPC for scored instruments, so there is no remote record to
    # wrap. Answers are held discretely as { loinc_link_id => ordinal } and the
    # FHIR resources are DERIVED from them on read — nothing is persisted as
    # prose, and the QuestionnaireResponse can never drift from the score.
    #
    # Only complete, scored administrations reach this table. An incomplete
    # instrument is reported back to the caller and written nowhere (issue #474:
    # "the form indicates the missing items and records no score").
    class ScreeningResponse < ApplicationRecord
      self.table_name = "lakeraven_ehr_screening_responses"

      # Who supplied the answers. `pre-visit` exists so the tokenized public
      # link (#471) can write through the SAME service and land in the SAME
      # table; nothing in this model or in ScreeningEntryService reads a
      # clinician session.
      SOURCE_CLINICIAN = "clinician"
      SOURCE_PRE_VISIT = "pre-visit"
      SOURCES = [ SOURCE_CLINICIAN, SOURCE_PRE_VISIT ].freeze

      # A visit number is an identifier, and " 2090061 " is the same visit as
      # "2090061" — leaving the padding in makes two visits out of one and
      # defeats any dedupe or lookup keyed on it.
      before_validation :normalize_encounter_ien

      validates :patient_dfn, presence: true
      validates :instrument_key, presence: true, inclusion: { in: ScreeningInstrument.keys }
      validates :total_score, presence: true, numericality: { only_integer: true }
      validates :severity_band, presence: true
      validates :effective_at, presence: true
      validates :source, inclusion: { in: SOURCES }
      # THE SAFETY INVARIANT — enforced here and in a database CHECK, not in
      # one service.
      #
      # A row whose ANSWERS disclose self-harm cannot exist without
      # acknowledgement evidence, whoever writes it: a console, an import, a
      # future caller, a restore, a second service. The service-level gate is a
      # UX affordance (it re-presents the prompt); it is not the enforcement
      # point, and while it was, a validated `create!` could store a positive
      # item 9 with `safety_flagged: false` and the dedupe window would then
      # hand that row back as a legitimate prior administration.
      #
      # The flag must MATCH the answers in both directions — an unflagged
      # disclosure hides it, and a flag with no disclosure behind it misreports
      # a patient as having disclosed self-harm.
      validate :safety_flag_matches_the_answers
      validates :safety_acknowledged_at, presence: true, if: :safety_flagged?
      # And for a clinician administration, WHO acknowledged. A pre-visit
      # self-report (#471) has no clinician by definition and is exempt.
      validates :safety_acknowledged_by, presence: true,
                if: -> { safety_flagged? && source == SOURCE_CLINICIAN }
      # A clinician administration recorded by nobody is unattributable —
      # whether or not it disclosed self-harm, and whatever wrote it.
      validates :administered_by, presence: true, if: -> { source == SOURCE_CLINICIAN }
      # The row is the source of truth for BOTH FHIR projections, so it may not
      # disagree with itself: the answers must cover the instrument, every value
      # must be a choice the instrument defines, and the stored total and band
      # must be the ones those answers produce. `total_score` and
      # `severity_band` were independent columns, validated only for presence —
      # answers summing to 18 could be stored as 999/"minimal" and the chart
      # and the Observation would both publish 999.
      validate :answers_agree_with_the_score

      scope :for_patient, ->(dfn) { where(patient_dfn: dfn).order(:effective_at, :id) }
      scope :for_instrument, ->(key) { where(instrument_key: key) }
      scope :safety_flagged, -> { where(safety_flagged: true) }

      # A submission token identifies the SUBMISSION this row came from, and a
      # unique index makes one submission at most one administration. It is
      # deliberately NOT an identity derived from the clinical content:
      #
      #   * a double-tap, a back-button replay and a retried POST are one
      #     submission arriving twice — same token, one row, and the unique
      #     index settles the race a check-then-insert cannot;
      #   * an instrument re-administered later the same day is a SECOND
      #     clinical event that happens to look identical, and comes from a
      #     newly rendered form, so it carries a new token and lands. Keying on
      #     the answers instead discarded it — common at the band extremes, and
      #     worse when the repeat re-disclosed self-harm, because only the
      #     first acknowledgement survived.
      #
      # Only the caller can tell a retry from a re-administration; the rendered
      # form is what knows. A caller that supplies no token is simply not
      # deduplicated (null, and Postgres treats nulls as distinct) rather than
      # having the distinction guessed for it.

      def instrument = ScreeningInstrument.find!(instrument_key)

      # True when this row can still be rendered and serialized at all. A row
      # naming an instrument that no longer exists (a direct write, a restore,
      # a retired instrument) is skipped by aggregate surfaces rather than
      # taking the whole page down with it.
      def renderable? = !ScreeningInstrument.find(instrument_key).nil?

      # Validation runs on WRITE. Reading is the other half of the contract: a
      # row can reach this table without ever meeting these invariants — a
      # direct write, a restore, an import, a release older than the
      # validations — and such a row must not be published as a `completed`
      # QuestionnaireResponse or a `final` Observation. Those statuses are
      # assertions about data, and this data disagrees with itself.
      #
      # Aggregate surfaces skip an unpublishable row and say so in the log;
      # they never repair it, because inventing the missing half is exactly
      # the failure mode being guarded against.
      def publishable? = renderable? && valid?

      # { link_id => ordinal }; jsonb round-trips values as strings under some
      # adapters, so PARSE on the way out — but a nil, blank or unparseable
      # value is UNANSWERED and is dropped, never coerced to 0. `.to_i` made
      # `nil` and `"banana"` read as ordinal 0, which on PHQ-9 item 9 is
      # "Not at all" — a negative self-harm screen manufactured out of absence
      # of data. 0 is a real clinical answer, so nothing may be allowed to
      # decay into it.
      def ordinals
        (answers || {}).each_with_object({}) do |(link_id, value), acc|
          ordinal = Integer(value.to_s, exception: false)
          next if ordinal.nil?

          acc[link_id.to_s] = ordinal
        end
      end

      # [ item, choice ] pairs for the items that carry a usable answer. An
      # ordinal with no matching choice is dropped rather than published as a
      # nil choice — a stored value the instrument does not define is not an
      # answer.
      def answered_items
        instrument.items.filter_map do |item|
          ordinal = ordinals[item.link_id]
          next if ordinal.nil?

          choice = instrument.choice_for(ordinal)
          next if choice.nil?

          [ item, choice ]
        end
      end

      # The total score as a FHIR Observation — a trendable, coded, dated
      # quantity, which is what #483 will chart. Reuses the engine's Observation
      # model so screening scores serialize through exactly the same path as
      # vitals and SDOH observations.
      def to_observation
        Observation.new(
          ien: observation_id,
          patient_dfn: patient_dfn.to_s,
          code: instrument.total_score_code,
          code_system: "loinc",
          display: instrument.total_score_display,
          value: total_score.to_s,
          value_quantity: total_score.to_s,
          unit: "{score}",
          category: "survey",
          status: "final",
          effective_datetime: effective_at
        )
      end

      def to_questionnaire_response
        Lakeraven::EHR::FHIR::QuestionnaireResponseSerializer.new(self).to_h
      end

      # Both halves of the persisted record, as FHIR: the item-level answers
      # (QuestionnaireResponse) and the trendable total (Observation).
      def to_fhir_resources = [ to_questionnaire_response, to_observation.to_fhir ]

      # Deterministic id (never random) so the resource keeps a stable,
      # resolvable identity across requests — same policy the chart applies to
      # vitals and problems.
      def observation_id = "screening-#{instrument_key}-#{id}"

      def safety_flagged? = safety_flagged

      # CSS-safe slug for the severity band. Bands are multi-word ("moderately
      # severe"), so this must parameterize the WHOLE label — taking the first
      # token collapses "moderately severe" onto "moderate", which is both the
      # wrong style hook and a misleading one, on the band where it matters
      # most. Defined here so the view and the stylesheet share one vocabulary.
      def severity_slug = severity_band.to_s.parameterize

      # True when the stored answers themselves disclose self-harm — the same
      # rule the instrument applies when scoring, read off the persisted row
      # rather than off whatever the caller passed.
      def answers_disclose_self_harm?
        definition = ScreeningInstrument.find(instrument_key)
        return false if definition.nil? || definition.safety_link_id.nil?

        ordinals[definition.safety_link_id].to_i.positive?
      end

      private

      def normalize_encounter_ien
        self.encounter_ien = encounter_ien.to_s.strip.presence unless encounter_ien.nil?
      end

      def safety_flag_matches_the_answers
        return if ScreeningInstrument.find(instrument_key).nil?
        return if safety_flagged? == answers_disclose_self_harm?

        if answers_disclose_self_harm?
          errors.add(:safety_flagged,
                     "must be set: these answers disclose self-harm and may only be stored acknowledged")
        else
          errors.add(:safety_flagged, "is set on answers that disclose no self-harm")
        end
      end

      def answers_agree_with_the_score
        definition = ScreeningInstrument.find(instrument_key)
        return if definition.nil? # instrument_key inclusion reports this

        stored = ordinals
        missing = definition.link_ids - stored.keys
        unknown = stored.keys - definition.link_ids
        invalid = stored.select { |_, ordinal| definition.choice_for(ordinal).nil? }.keys

        errors.add(:answers, "must answer every #{definition.short_title} item") if missing.any?
        errors.add(:answers, "names items that are not part of #{definition.short_title}") if unknown.any?
        errors.add(:answers, "contains values that are not choices on this instrument") if invalid.any?
        return if errors[:answers].any?

        errors.add(:total_score, "must equal the sum of the answers") unless total_score == stored.values.sum
        return unless total_score == stored.values.sum

        expected_band = definition.band_label_for(total_score)
        return if severity_band.to_s == expected_band.to_s

        errors.add(:severity_band, "must be #{expected_band.inspect} for a total of #{total_score}")
      end
    end
  end
end
