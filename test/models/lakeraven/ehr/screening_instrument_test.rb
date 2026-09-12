# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ScreeningInstrumentTest < ActiveSupport::TestCase
      PHQ9 = ScreeningInstrument::PHQ9
      GAD7 = ScreeningInstrument::GAD7

      def answers_for(instrument, values)
        instrument.link_ids.zip(values).to_h
      end

      def all_answered(instrument, value)
        instrument.link_ids.index_with { value }
      end

      # -- Shape ---------------------------------------------------------------

      test "PHQ-9 has nine items scored 0-3 for a maximum of 27" do
        assert_equal 9, PHQ9.items.length
        assert_equal (1..9).to_a, PHQ9.items.map(&:position)
        assert_equal [ 0, 1, 2, 3 ], ScreeningInstrument::CHOICES.map(&:value)
        assert_equal 27, PHQ9.max_score
      end

      test "GAD-7 has seven items for a maximum of 21" do
        assert_equal 7, GAD7.items.length
        assert_equal 21, GAD7.max_score
      end

      test "instruments are addressable by key and unknown keys raise" do
        assert_equal PHQ9, ScreeningInstrument.find("phq-9")
        assert_equal GAD7, ScreeningInstrument.find("gad-7")
        assert_nil ScreeningInstrument.find("phq-2")
        assert_raises(ArgumentError) { ScreeningInstrument.find!("phq-2") }
      end

      test "every link id is a distinct LOINC item code" do
        ScreeningInstrument::ALL.each do |instrument|
          assert_equal instrument.link_ids.uniq, instrument.link_ids
          instrument.link_ids.each { |id| assert_match(/\A\d+-\d\z/, id) }
        end
      end

      test "total score codes are LOINC TOTAL SCORE codes, not panel codes" do
        # 44249-1 is the PHQ-9 panel; 44261-6 is the total score. Issue #474
        # originally named the panel code — corrected here and in the issue.
        assert_equal "44261-6", PHQ9.total_score_code
        assert_not_equal PHQ9.panel_code, PHQ9.total_score_code
        # 70274-6 is genuinely the GAD-7 total score, distinct from panel 69737-5.
        assert_equal "70274-6", GAD7.total_score_code
        assert_not_equal GAD7.panel_code, GAD7.total_score_code
      end

      test "questionnaire canonical is the LOINC panel URI" do
        assert_equal "http://loinc.org/q/44249-1", PHQ9.questionnaire_canonical
        assert_equal "http://loinc.org/q/69737-5", GAD7.questionnaire_canonical
      end

      # -- Scoring -------------------------------------------------------------

      test "PHQ-9 sums the nine ordinals" do
        score = PHQ9.score(answers_for(PHQ9, [ 3, 2, 1, 0, 3, 2, 1, 0, 0 ]))

        assert score.complete?
        assert score.scored?
        assert_equal 12, score.total
      end

      test "GAD-7 sums the seven ordinals" do
        score = GAD7.score(answers_for(GAD7, [ 2, 2, 2, 1, 1, 0, 0 ]))

        assert_equal 8, score.total
      end

      test "an all-zero instrument scores zero, not nil" do
        score = PHQ9.score(all_answered(PHQ9, 0))

        assert_equal 0, score.total
        assert score.scored?
      end

      test "a maxed instrument scores its ceiling" do
        assert_equal 27, PHQ9.score(all_answered(PHQ9, 3)).total
        assert_equal 21, GAD7.score(all_answered(GAD7, 3)).total
      end

      # -- Banding -------------------------------------------------------------

      test "PHQ-9 severity bands cover 0-27 at every boundary" do
        expected = {
          0 => "minimal", 4 => "minimal",
          5 => "mild", 9 => "mild",
          10 => "moderate", 14 => "moderate",
          15 => "moderately severe", 19 => "moderately severe",
          20 => "severe", 27 => "severe"
        }
        expected.each { |total, band| assert_equal band, PHQ9.band_label_for(total), "total #{total}" }
        (0..27).each { |total| assert_not_nil PHQ9.band_label_for(total), "total #{total} unbanded" }
      end

      test "GAD-7 severity bands cover 0-21 at every boundary" do
        expected = {
          0 => "minimal", 4 => "minimal",
          5 => "mild", 9 => "mild",
          10 => "moderate", 14 => "moderate",
          15 => "severe", 21 => "severe"
        }
        expected.each { |total, band| assert_equal band, GAD7.band_label_for(total), "total #{total}" }
        (0..21).each { |total| assert_not_nil GAD7.band_label_for(total), "total #{total} unbanded" }
      end

      test "score carries the band alongside the total" do
        score = PHQ9.score(all_answered(PHQ9, 2)) # 18

        assert_equal 18, score.total
        assert_equal "moderately severe", score.band
      end

      # -- Incomplete ----------------------------------------------------------

      test "an incomplete instrument is not scored and names its missing items" do
        answers = answers_for(PHQ9, [ 1, 1, 1, 1, 1, 1, 1, nil, nil ]).compact
        score = PHQ9.score(answers)

        assert_not score.complete?
        assert_not score.scored?
        assert_nil score.total
        assert_nil score.band
        assert_equal %w[44253-3 44260-8], score.missing_link_ids
        assert_equal [ 8, 9 ], score.missing_positions
      end

      test "blank, non-numeric and out-of-range answers count as unanswered" do
        answers = all_answered(PHQ9, 1).merge(
          PHQ9.items[0].link_id => "",
          PHQ9.items[1].link_id => "banana",
          PHQ9.items[2].link_id => 4,
          PHQ9.items[3].link_id => -1
        )
        score = PHQ9.score(answers)

        assert_not score.scored?
        assert_equal PHQ9.link_ids.first(4), score.missing_link_ids
      end

      test "answers for unknown link ids are ignored" do
        answers = all_answered(PHQ9, 1).merge("99999-9" => 3)

        assert_equal 9, PHQ9.score(answers).total
      end

      test "string ordinals from a form post score identically to integers" do
        assert_equal 9, PHQ9.score(all_answered(PHQ9, "1")).total
      end

      test "nil answers score nothing rather than raising" do
        score = PHQ9.score(nil)

        assert_not score.scored?
        assert_equal PHQ9.link_ids, score.missing_link_ids
      end

      # -- Item 9 safety -------------------------------------------------------

      test "PHQ-9 item 9 is the self-harm safety item" do
        assert PHQ9.safety_item?
        assert_equal "44260-8", PHQ9.safety_link_id
        assert_equal 9, PHQ9.safety_item.position
      end

      test "GAD-7 has no safety item" do
        assert_not GAD7.safety_item?
        assert_not GAD7.score(all_answered(GAD7, 3)).safety_triggered?
      end

      test "item 9 answered not at all does not trigger the safety prompt" do
        assert_not PHQ9.score(all_answered(PHQ9, 0)).safety_triggered?
      end

      test "any item 9 answer above not at all triggers the safety prompt" do
        [ 1, 2, 3 ].each do |ordinal|
          answers = all_answered(PHQ9, 0).merge(PHQ9.safety_link_id => ordinal)

          assert PHQ9.score(answers).safety_triggered?, "ordinal #{ordinal} should trigger"
        end
      end

      test "a positive item 9 triggers even when the rest of the instrument is blank" do
        score = PHQ9.score(PHQ9.safety_link_id => 1)

        assert score.safety_triggered?
        assert_not score.complete?
      end
    end
  end
end
