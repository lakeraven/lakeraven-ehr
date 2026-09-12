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

      validates :patient_dfn, presence: true
      validates :instrument_key, presence: true, inclusion: { in: ScreeningInstrument.keys }
      validates :total_score, presence: true, numericality: { only_integer: true }
      validates :severity_band, presence: true
      validates :effective_at, presence: true
      validates :source, inclusion: { in: SOURCES }
      # A safety-flagged row is, by construction, one that passed the
      # acknowledgement gate — so it must carry the trace. An acknowledging DUZ
      # is NOT required: a pre-visit self-report (#471) has no clinician.
      validates :safety_acknowledged_at, presence: true, if: :safety_flagged?

      scope :for_patient, ->(dfn) { where(patient_dfn: dfn).order(:effective_at, :id) }
      scope :for_instrument, ->(key) { where(instrument_key: key) }
      scope :safety_flagged, -> { where(safety_flagged: true) }

      def instrument = ScreeningInstrument.find!(instrument_key)

      # { link_id => ordinal }; jsonb round-trips values as strings under some
      # adapters, so coerce on the way out.
      def ordinals = (answers || {}).transform_values(&:to_i)

      def answered_items
        instrument.items.filter_map do |item|
          ordinal = ordinals[item.link_id]
          next if ordinal.nil?

          [ item, instrument.choice_for(ordinal) ]
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
    end
  end
end
