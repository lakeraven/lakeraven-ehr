# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ScreeningEntryServiceTest < ActiveSupport::TestCase
      PHQ9 = ScreeningInstrument::PHQ9
      GAD7 = ScreeningInstrument::GAD7
      DFN = 1
      VISIT = "2090061"

      teardown { ScreeningResponse.delete_all }

      def all_answered(instrument, value) = instrument.link_ids.index_with { value }

      # A complete set that deliberately leaves the self-harm item at "not at
      # all", so tests about everything else are not fighting the safety gate.
      def complete_without_safety_flag(instrument)
        answers = all_answered(instrument, 1)
        answers[instrument.safety_link_id] = 0 if instrument.safety_item?
        answers
      end

      def save(instrument: PHQ9, answers: nil, **overrides)
        ScreeningEntryService.new(
          instrument: instrument,
          patient_dfn: DFN,
          encounter_ien: VISIT,
          answers: answers || complete_without_safety_flag(instrument),
          **overrides
        ).save
      end

      # -- Happy path ----------------------------------------------------------

      test "a complete PHQ-9 is scored, banded and stored discretely" do
        answers = PHQ9.link_ids.zip([ 3, 2, 2, 2, 1, 1, 1, 0, 0 ]).to_h
        result = save(answers: answers)

        assert result.success?, result.error.inspect
        record = result.record
        assert_equal 12, record.total_score
        assert_equal "moderate", record.severity_band
        assert_equal "phq-9", record.instrument_key
        assert_equal VISIT, record.encounter_ien
        assert_equal ScreeningResponse::SOURCE_CLINICIAN, record.source
        # Discrete answers, keyed by LOINC link id — not prose.
        assert_equal answers.transform_values(&:to_i), record.ordinals
      end

      test "a complete GAD-7 is scored and banded" do
        result = save(instrument: GAD7, answers: GAD7.link_ids.zip([ 3, 3, 3, 3, 3, 0, 0 ]).to_h)

        assert result.success?
        assert_equal 15, result.record.total_score
        assert_equal "severe", result.record.severity_band
      end

      test "the record carries an effective date so the score can trend" do
        moment = Time.utc(2026, 3, 1, 14, 30)
        result = save(effective_at: moment)

        assert_in_delta moment, result.record.effective_at, 1.second
      end

      test "effective date defaults to now rather than being left blank" do
        assert_not_nil save.record.effective_at
      end

      test "the administering clinician is recorded" do
        assert_equal "99999", save(administered_by: "99999").record.administered_by
      end

      # -- Incomplete: not scored, nothing written -----------------------------

      test "an incomplete instrument records no score and names the missing items" do
        answers = all_answered(PHQ9, 1).except(PHQ9.items[2].link_id, PHQ9.items[7].link_id)
        result = save(answers: answers)

        assert_not result.success?
        assert_equal :incomplete, result.error
        assert_equal [ PHQ9.items[2].link_id, PHQ9.items[7].link_id ].sort, result.missing_link_ids.sort
        assert_nil result.score.total
        assert_equal 0, ScreeningResponse.count
      end

      test "an empty submission is incomplete rather than a zero score" do
        result = save(answers: {})

        assert_equal :incomplete, result.error
        assert_equal PHQ9.link_ids, result.missing_link_ids
        assert_equal 0, ScreeningResponse.count
      end

      # -- Item 9 safety gate --------------------------------------------------

      test "a positive item 9 blocks the save until it is acknowledged" do
        answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
        result = save(answers: answers)

        assert_not result.success?
        assert_equal :safety_unacknowledged, result.error
        assert result.safety_prompt_required?
        assert_equal 0, ScreeningResponse.count
      end

      test "acknowledging the safety prompt lets the same answers through" do
        answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
        result = save(answers: answers, safety_acknowledged: true)

        assert result.success?, result.error.inspect
        assert_equal 2, result.record.total_score
        assert result.record.safety_flagged?
      end

      test "a saved screening with item 9 at not at all is not safety flagged" do
        assert_not save(answers: all_answered(PHQ9, 0)).record.safety_flagged?
      end

      test "an incomplete instrument with a positive item 9 still raises the prompt" do
        answers = { PHQ9.safety_link_id => 3 }
        result = save(answers: answers)

        assert_equal :incomplete, result.error
        assert result.safety_prompt_required?, "self-harm disclosure must surface before the form is finished"
      end

      test "the safety gate does not apply to GAD-7" do
        result = save(instrument: GAD7, answers: all_answered(GAD7, 3))

        assert result.success?
        assert_not result.record.safety_flagged?
      end

      # -- Guards --------------------------------------------------------------

      test "a clinician administration requires an open encounter" do
        result = save(encounter_ien: nil)

        assert_equal :missing_encounter, result.error
        assert_equal 0, ScreeningResponse.count
      end

      test "a missing patient is rejected" do
        result = ScreeningEntryService.new(
          instrument: PHQ9, patient_dfn: nil, encounter_ien: VISIT, answers: all_answered(PHQ9, 1)
        ).save

        assert_equal :invalid_input, result.error
      end

      test "an unrecognised source is rejected" do
        assert_equal :invalid_source, save(source: "anonymous-internet").error
      end

      test "the instrument may be named by key" do
        result = ScreeningEntryService.new(
          instrument: "gad-7", patient_dfn: DFN, encounter_ien: VISIT, answers: all_answered(GAD7, 1)
        ).save

        assert result.success?
        assert_equal "gad-7", result.record.instrument_key
      end

      # -- Pre-visit seam (#471) -----------------------------------------------

      test "a pre-visit submission needs no session, no clinician and no encounter" do
        result = ScreeningEntryService.new(
          instrument: GAD7,
          patient_dfn: DFN,
          answers: all_answered(GAD7, 1),
          source: ScreeningResponse::SOURCE_PRE_VISIT
        ).save

        assert result.success?, result.error.inspect
        assert_equal ScreeningResponse::SOURCE_PRE_VISIT, result.record.source
        assert_nil result.record.encounter_ien
        assert_nil result.record.administered_by
        assert_equal 7, result.record.total_score
      end

      test "a pre-visit submission is held to the same safety gate" do
        answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 1)
        result = ScreeningEntryService.new(
          instrument: PHQ9, patient_dfn: DFN, answers: answers,
          source: ScreeningResponse::SOURCE_PRE_VISIT
        ).save

        assert_equal :safety_unacknowledged, result.error
        assert_equal 0, ScreeningResponse.count
      end
    end
  end
end
