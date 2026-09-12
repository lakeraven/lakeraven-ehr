# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # The stored administration is the source of truth for BOTH FHIR
    # projections, so it has to be internally consistent — and it has to stay
    # safe when a row is not, because a row can reach this table by a path that
    # never ran these validations (a direct write, a restore, an older release).
    class ScreeningResponseTest < ActiveSupport::TestCase
      PHQ9 = ScreeningInstrument::PHQ9
      SAFETY = PHQ9.safety_link_id

      teardown { ScreeningResponse.delete_all }

      # A consistent PHQ-9: every item answered 2, total 18, "moderately severe".
      def valid_record(**overrides)
        ScreeningResponse.create!({
          patient_dfn: 1, encounter_ien: "2090061", instrument_key: "phq-9",
          answers: PHQ9.link_ids.index_with { 2 },
          total_score: 18, severity_band: "moderately severe",
          effective_at: Time.utc(2026, 3, 1), source: "clinician",
          safety_flagged: true, safety_acknowledged_at: Time.utc(2026, 3, 1),
          safety_acknowledged_by: "99999"
        }.merge(overrides))
      end

      def build(**overrides)
        ScreeningResponse.new({
          patient_dfn: 1, instrument_key: "phq-9",
          answers: PHQ9.link_ids.index_with { 2 },
          total_score: 18, severity_band: "moderately severe",
          effective_at: Time.utc(2026, 3, 1), source: "clinician"
        }.merge(overrides))
      end

      # -- The row may not disagree with itself (#5) ---------------------------

      test "a consistent administration is valid" do
        assert build.valid?, build.errors.full_messages.inspect
      end

      test "an empty answers hash with a maximal score is invalid" do
        assert_not build(answers: {}, total_score: 27, severity_band: "severe").valid?
      end

      test "a total score that is not the sum of the answers is invalid" do
        record = build(total_score: 999, severity_band: "minimal")

        assert_not record.valid?, "999 must not be storable against answers summing to 18"
        assert_includes record.errors.full_messages.join(" "), "sum"
      end

      test "a severity band that does not match the total is invalid" do
        record = build(severity_band: "minimal")

        assert_not record.valid?, "the band must be derived from the total, not asserted"
      end

      test "answers that do not cover every item are invalid" do
        record = build(answers: PHQ9.link_ids.index_with { 2 }.except(SAFETY), total_score: 16)

        assert_not record.valid?, "a partial instrument must not be storable as a score"
      end

      test "an answer outside the instrument's choice list is invalid" do
        answers = PHQ9.link_ids.index_with { 2 }.merge(SAFETY => 9)
        record = build(answers: answers, total_score: 25, severity_band: "severe")

        assert_not record.valid?, "9 is not an ordinal on the LL358-3 answer list"
      end

      test "an answer under a link id the instrument does not declare is invalid" do
        answers = PHQ9.link_ids.index_with { 2 }.merge("99999-9" => 2)
        record = build(answers: answers, total_score: 20, severity_band: "severe")

        assert_not record.valid?
      end

      test "a safety flagged row must carry its acknowledgement timestamp" do
        assert_not build(safety_flagged: true).valid?,
                   "a flagged row is one that passed the gate — it must say when"
      end

      # -- An unanswered item is never "Not at all" (#3) -----------------------
      #
      # `.to_i` turned nil and "banana" into 0, which on PHQ-9 item 9 is a
      # NEGATIVE self-harm screen manufactured out of absence of data.

      [ nil, "banana", "" ].each do |stored|
        test "a stored item-9 value of #{stored.inspect} is unanswered, not Not at all" do
          record = valid_record
          record.update_column(:answers, record.answers.merge(SAFETY => stored))
          record.reload

          assert_nil record.ordinals[SAFETY], "#{stored.inspect} must not read as ordinal 0"
          assert_empty record.answered_items.select { |item, _| item.link_id == SAFETY }

          item9 = record.to_questionnaire_response[:item].find { |i| i[:linkId] == SAFETY }
          assert_nil item9, "an unanswered self-harm item must not be published as an answer"
        end
      end

      test "a genuine zero on item 9 is still Not at all" do
        record = valid_record(answers: PHQ9.link_ids.index_with { 2 }.merge(SAFETY => 0),
                              total_score: 16, severity_band: "moderately severe",
                              safety_flagged: false, safety_acknowledged_at: nil,
                              safety_acknowledged_by: nil)

        assert_equal 0, record.ordinals[SAFETY]
        item9 = record.to_questionnaire_response[:item].find { |i| i[:linkId] == SAFETY }
        assert_equal "Not at all", item9.dig(:answer, 0, :valueCoding, :display)
      end

      test "jsonb string round-trips still parse as ordinals" do
        record = valid_record
        record.update_column(:answers, record.answers.transform_values(&:to_s))
        record.reload

        assert_equal 2, record.ordinals[SAFETY]
      end

      # -- A malformed row degrades, it does not raise (#6) --------------------

      test "an out-of-range stored ordinal is omitted rather than raising" do
        record = valid_record
        record.update_column(:answers, record.answers.merge(SAFETY => 9))
        record.reload

        resource = nil
        assert_nothing_raised { resource = record.to_questionnaire_response }
        assert_nil resource[:item].find { |i| i[:linkId] == SAFETY },
                   "an ordinal with no choice must be dropped, never guessed"
        assert_equal 8, resource[:item].length
      end
    end
  end
end
