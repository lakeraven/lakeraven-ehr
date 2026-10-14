# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitFinalizationServiceTest < ActiveSupport::TestCase
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      teardown { BehavioralHealthVisitCoding.delete_all }

      test "finalize succeeds when visit coding is resolved" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 30,
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_061)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        assert result.success?
        assert encounter.finished?
      end

      test "finalize fails when visit coding is unresolved" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 15,
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_061)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_unresolved, result.error
        refute encounter.finished?
      end

      test "finalize fails closed when visit coding is absent" do
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_061)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: nil
        ).finalize

        refute result.success?
        assert_equal :coding_missing, result.error
        refute encounter.finished?
      end

      test "finalize fails when clinician-selected CPT is inconsistent with documented duration" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 30,
          selected_cpt_code: "90837",
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_061)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_unresolved, result.error
        refute encounter.finished?
      end
    end
  end
end
