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
        result = save(answers: answers, safety_acknowledged: true, administered_by: "99999")

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

      # The gate is a clinical-safety control, so it decides for itself what an
      # acknowledgement is rather than trusting a caller to have coerced one.
      # An ALLOWLIST, not a cast. `ActiveModel::Type::Boolean` returns false
      # only for its own fixed falsy set, so every one of "banana", "no",
      # "off-duty", "0.0" and "null" casts TRUE — a cast can only reject the
      # bad values someone thought of, and this gate was wrong three rounds
      # running for exactly that reason.
      FALSY_ACKNOWLEDGEMENTS = [
        false, nil, "false", "0", "", 0, [], {}, [ "" ], [ "false" ],
        "banana", "no", "null", "0.0", "off-duty", "-1", "acknowledged?",
        1, "on", "yes", "t", "T", "TRUE", "True", " 1", "1 ", :true, 1.0
      ].freeze

      FALSY_ACKNOWLEDGEMENTS.each do |value|
        test "safety_acknowledged: #{value.inspect} does not acknowledge the gate" do
          answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
          result = save(answers: answers, safety_acknowledged: value)

          assert_equal :safety_unacknowledged, result.error,
                       "#{value.inspect} opened the item-9 safety gate"
          assert_equal 0, ScreeningResponse.count,
                       "#{value.inspect} persisted an unacknowledged self-harm disclosure"
        end
      end

      # The whole allowlist, and nothing else. Kept small on purpose: the form
      # posts "1", a programmatic caller passes `true`.
      [ true, "true", "1" ].each do |value|
        test "safety_acknowledged: #{value.inspect} acknowledges the gate" do
          answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
          result = save(answers: answers, safety_acknowledged: value, administered_by: "99999")

          assert result.success?, "#{value.inspect} should acknowledge: #{result.error.inspect}"
        end
      end

      # -- Acknowledgement leaves a durable trace -------------------------------

      # A clinician administration that reaches the table with a self-harm
      # disclosure must name the clinician who acknowledged it. Round 2 added
      # the column and left it optional in exactly the case it was added for.
      test "a clinician acknowledgement with no clinician is refused" do
        answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
        result = save(answers: answers, safety_acknowledged: true, administered_by: nil)

        assert_not result.success?, "an anonymous clinician acknowledgement must not persist"
        assert_includes result.errors, :missing_administered_by
        assert_equal 0, ScreeningResponse.count
      end

      test "a pre-visit self-report still needs no clinician" do
        answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
        result = ScreeningEntryService.new(
          instrument: PHQ9, patient_dfn: DFN, answers: answers,
          source: ScreeningResponse::SOURCE_PRE_VISIT, safety_acknowledged: true
        ).save

        assert result.success?, result.errors.inspect
        assert_not_nil result.record.safety_acknowledged_at
        assert_nil result.record.safety_acknowledged_by
      end

      test "an acknowledged self-harm disclosure records when and by whom" do
        answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
        record = save(answers: answers, safety_acknowledged: true, administered_by: "99999").record

        assert record.safety_flagged?
        assert_not_nil record.safety_acknowledged_at,
                       "an acknowledged row must be distinguishable from one that bypassed the gate"
        assert_equal "99999", record.safety_acknowledged_by
      end

      test "a screening with no safety flag carries no acknowledgement trace" do
        record = save(administered_by: "99999").record

        assert_not record.safety_flagged?
        assert_nil record.safety_acknowledged_at
        assert_nil record.safety_acknowledged_by
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

      # "We could not determine" must name every reason it could not, or the
      # clinician fixes the visit number, resubmits, and only then learns eight
      # items are unanswered.
      test "a submission missing both a visit and answers reports both reasons" do
        missing = [ PHQ9.items[2].link_id, PHQ9.items[7].link_id ]
        result = save(encounter_ien: nil, answers: all_answered(PHQ9, 1).except(*missing))

        assert_includes result.errors, :missing_encounter
        assert_includes result.errors, :incomplete
        assert_equal missing.sort, result.missing_link_ids.sort
        assert_equal 0, ScreeningResponse.count
      end

      test "a submission missing a visit, answers, a clinician and acknowledgement reports all four" do
        answers = { PHQ9.safety_link_id => 3 }
        result = save(encounter_ien: nil, answers: answers)

        assert_equal %i[missing_encounter incomplete safety_unacknowledged missing_administered_by].sort,
                     result.errors.sort
        assert result.safety_prompt_required?
      end

      # -- Idempotency ---------------------------------------------------------
      #
      # The thing that must be idempotent is a SUBMISSION, not an
      # administration: a double-tap, a back-button replay and a retried POST
      # are one submission arriving twice, while the same instrument
      # re-administered later that day is a second clinical event that happens
      # to look identical. Only the caller can tell those apart, and the
      # rendered form does: it carries a submission token.

      def token = SecureRandom.uuid

      test "the same submission token twice records one administration" do
        t = token
        first = save(answers: complete_without_safety_flag(PHQ9), submission_token: t)
        second = save(answers: complete_without_safety_flag(PHQ9), submission_token: t)

        assert second.success?
        assert second.duplicate?
        assert_equal first.record.id, second.record.id
        assert_equal 1, ScreeningResponse.count
      end

      # The event this feature exists to trend. An 08:00 screen and a 16:00
      # re-screen with identical answers are two administrations — common at
      # the band extremes, and discarding the second while reporting success
      # loses a real clinical event.
      test "a re-screen later the same day is its own administration" do
        save(answers: complete_without_safety_flag(PHQ9), submission_token: token,
             effective_at: Time.zone.parse("2026-03-01 08:00"))
        second = save(answers: complete_without_safety_flag(PHQ9), submission_token: token,
                      effective_at: Time.zone.parse("2026-03-01 16:00"))

        assert_not second.duplicate?
        assert_equal 2, ScreeningResponse.count
      end

      # And if the repeat re-discloses self-harm, the afternoon acknowledgement
      # must exist in its own right — not be collapsed into the morning's.
      test "a re-disclosure of self-harm keeps its own acknowledgement" do
        disclosing = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => 2)
        morning = save(answers: disclosing, submission_token: token, safety_acknowledged: true,
                       administered_by: "99999", effective_at: Time.zone.parse("2026-03-01 08:00"))
        afternoon = save(answers: disclosing, submission_token: token, safety_acknowledged: true,
                         administered_by: "99999", effective_at: Time.zone.parse("2026-03-01 16:00"))

        assert_not afternoon.duplicate?
        assert_equal 2, ScreeningResponse.safety_flagged.count
        assert_not_equal morning.record.safety_acknowledged_at,
                         afternoon.record.safety_acknowledged_at
      end

      # A resubmission of the same form with CHANGED answers is not the retry
      # the token stands for. Refuse and say so rather than returning the old
      # row as though the correction had been recorded.
      test "a submission token cannot be reused for different answers" do
        t = token
        save(answers: complete_without_safety_flag(PHQ9), submission_token: t)
        again = save(answers: all_answered(PHQ9, 0), submission_token: t)

        assert_not again.success?
        assert_equal :already_submitted, again.error
        assert_equal 1, ScreeningResponse.count
      end

      # A token is an idempotency key, never an authorization one: presenting
      # someone else's cannot hand you their record.
      test "a submission token from another patient is refused, not returned" do
        t = token
        save(answers: complete_without_safety_flag(PHQ9), submission_token: t)
        other = ScreeningEntryService.new(
          instrument: PHQ9, patient_dfn: 2, encounter_ien: VISIT,
          answers: complete_without_safety_flag(PHQ9), submission_token: t
        ).save

        assert_not other.success?
        assert_equal :already_submitted, other.error
        assert_nil other.record
      end

      test "a caller that supplies no token gets no deduplication" do
        save(answers: complete_without_safety_flag(PHQ9))
        save(answers: complete_without_safety_flag(PHQ9))

        assert_equal 2, ScreeningResponse.count
      end

      test "the stored visit number is normalized" do
        record = save(answers: complete_without_safety_flag(PHQ9), encounter_ien: "  #{VISIT} ").record

        assert_equal VISIT, record.encounter_ien
      end

      # An unacknowledged or self-contradicting row must never be handed back as
      # a legitimate prior administration — that would let a row written around
      # the model launder itself into the clinical record on a clinician's
      # next submission.
      test "a corrupt row behind this token is refused, not laundered" do
        t = token
        first = save(answers: complete_without_safety_flag(PHQ9), submission_token: t).record
        first.update_column(:total_score, 999)

        again = save(answers: complete_without_safety_flag(PHQ9), submission_token: t)

        assert_not again.success?, "a row that fails its own invariants is not a prior submission"
        assert_equal :conflicting_record, again.error
        assert_nil again.record
      end

      # The lost side of a race: the winning request has already inserted, and
      # this one's lookup could not see it. The unique index refuses the second
      # insert and the caller gets the SAME administration back, which is what
      # it would have got a millisecond later.
      test "a submission that loses the insert race still gets one administration back" do
        t = token
        first = save(answers: complete_without_safety_flag(PHQ9), submission_token: t).record

        # The interleaving itself: this request's pre-insert lookup runs BEFORE
        # the winner commits and sees nothing, so it goes on to insert. Every
        # later lookup sees the committed row, as a real connection would.
        blind = Class.new(SimpleDelegator) do
          def find_by(...)
            return super if @looked_up

            @looked_up = true
            nil
          end
        end.new(ScreeningResponse)

        racing = save(answers: complete_without_safety_flag(PHQ9), submission_token: t,
                      repository: blind)

        assert racing.success?, racing.error.inspect
        assert racing.duplicate?
        assert_equal first.id, racing.record.id
        assert_equal 1, ScreeningResponse.count
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
