# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PsychotherapyVisitCodingRulesTest < ActiveSupport::TestCase
      EVAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_PSYCHIATRIC_DIAGNOSTIC_EVALUATION
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      test "default code offered for the first visit of a new behavioral-health episode is 90791" do
        assert_equal "90791", PsychotherapyVisitCodingRules.default_cpt_code_for_new_episode
      end

      test "psychiatric diagnostic evaluation is reportable as 90791 with no time requirement" do
        [ nil, 0, 15, 120 ].each do |minutes|
          proposal = PsychotherapyVisitCodingRules.proposal(encounter_kind: EVAL, duration_minutes: minutes)

          assert proposal.reportable?, "expected 90791 to be reportable at #{minutes.inspect} minutes"
          assert_equal "90791", proposal.cpt_code
          assert_nil proposal.blocking_reason
        end
      end

      test "psychiatric diagnostic evaluation rejects non-integer and fractional duration values" do
        [ -0.5, "bad", false, 1.5 ].each do |minutes|
          proposal = PsychotherapyVisitCodingRules.proposal(encounter_kind: EVAL, duration_minutes: minutes)

          refute proposal.reportable?, "expected refusal at #{minutes.inspect} minutes"
          assert_nil proposal.cpt_code
          assert_equal :invalid_duration, proposal.blocking_reason
        end
      end

      test "psychiatric diagnostic evaluation nil zero and positive integer minutes remain reportable as 90791" do
        [ nil, 0, 1, 15 ].each do |minutes|
          proposal = PsychotherapyVisitCodingRules.proposal(encounter_kind: EVAL, duration_minutes: minutes)

          assert proposal.reportable?, "expected 90791 to be reportable at #{minutes.inspect} minutes"
          assert_equal "90791", proposal.cpt_code
          assert_nil proposal.blocking_reason
        end
      end

      test "individual psychotherapy duration band edges map to 90832 90834 90837" do
        expectations = {
          16 => "90832",
          37 => "90832",
          38 => "90834",
          52 => "90834",
          53 => "90837",
          90 => "90837"
        }

        expectations.each do |minutes, code|
          proposal = PsychotherapyVisitCodingRules.proposal(encounter_kind: INDIVIDUAL, duration_minutes: minutes)

          assert proposal.reportable?, "expected #{code} at #{minutes} minutes"
          assert_equal code, proposal.cpt_code
        end
      end

      test "individual psychotherapy under 16 minutes is not reportable" do
        proposal = PsychotherapyVisitCodingRules.proposal(encounter_kind: INDIVIDUAL, duration_minutes: 15)

        refute proposal.reportable?
        assert_nil proposal.cpt_code
        assert_equal :below_minimum_duration, proposal.blocking_reason
      end

      test "individual psychotherapy with missing duration is not reportable" do
        proposal = PsychotherapyVisitCodingRules.proposal(encounter_kind: INDIVIDUAL, duration_minutes: nil)

        refute proposal.reportable?
        assert_nil proposal.cpt_code
        assert_equal :missing_duration, proposal.blocking_reason
      end

      test "individual psychotherapy rejects zero and negative duration" do
        [ 0, -1, -30 ].each do |minutes|
          proposal = PsychotherapyVisitCodingRules.proposal(encounter_kind: INDIVIDUAL, duration_minutes: minutes)

          refute proposal.reportable?
          assert_nil proposal.cpt_code
          assert_equal :invalid_duration, proposal.blocking_reason
        end
      end

      test "allowed psychotherapy CPT codes are numeric only and do not embed AMA descriptor text" do
        codes = PsychotherapyVisitCodingRules::ALLOWED_CPT_CODES

        assert_equal %w[90791 90832 90834 90837], codes
        codes.each do |code|
          assert_match(/\A\d{5}\z/, code)
          refute_includes PsychotherapyVisitCodingRules::ALLOWED_CPT_CODES.join(" "), "psychotherapy",
                          "CPT descriptor prose must not live in engine constants (BYO licensed content, #55)"
        end
      end

      test "LicensedCptContent display is host-provided and absent by default" do
        assert_nil LicensedCptContent.display_for("90834")
        LicensedCptContent.descriptor_provider = ->(code) { "host-label-#{code}" }
        assert_equal "host-label-90834", LicensedCptContent.display_for("90834")
      ensure
        LicensedCptContent.descriptor_provider = LicensedCptContent::NULL_PROVIDER
      end

      test "clinician-selected CPT must fall within the duration band for individual psychotherapy" do
        proposal = PsychotherapyVisitCodingRules.proposal(
          encounter_kind: INDIVIDUAL,
          duration_minutes: 30,
          selected_cpt_code: "90837"
        )

        refute proposal.reportable?
        assert_nil proposal.cpt_code
        assert_equal :selection_inconsistent_with_duration, proposal.blocking_reason
      end

      test "a consistent clinician selection is reportable as the selected code" do
        proposal = PsychotherapyVisitCodingRules.proposal(
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          selected_cpt_code: "90834"
        )

        assert proposal.reportable?
        assert_equal "90834", proposal.cpt_code
        assert_nil proposal.blocking_reason
      end

      test "clinician-selected codes outside the psychotherapy set are not reportable" do
        proposal = PsychotherapyVisitCodingRules.proposal(
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          selected_cpt_code: "90853"
        )

        refute proposal.reportable?
        assert_equal :disallowed_cpt_code, proposal.blocking_reason
      end

      test "90791 cannot be selected on an individual psychotherapy encounter" do
        proposal = PsychotherapyVisitCodingRules.proposal(
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          selected_cpt_code: "90791"
        )

        refute proposal.reportable?
        assert_equal :cpt_code_incompatible_with_encounter_kind, proposal.blocking_reason
      end

      test "individual psychotherapy codes require documented duration even when selected" do
        proposal = PsychotherapyVisitCodingRules.proposal(
          encounter_kind: INDIVIDUAL,
          duration_minutes: nil,
          selected_cpt_code: "90834"
        )

        refute proposal.reportable?
        assert_equal :missing_duration, proposal.blocking_reason
      end
    end
  end
end
