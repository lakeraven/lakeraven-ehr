# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitFinalizationFinishedEncounterTest < ActiveSupport::TestCase
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      teardown { BehavioralHealthVisitCoding.delete_all }

      test "finalize refuses already finished encounter when visit coding is missing" do
        encounter = Encounter.new(
          status: "finished",
          period_end: nil,
          class_code: "AMB",
          ien: 2_090_101,
          patient_dfn: 8801
        )

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: nil
        ).finalize

        refute result.success?
        assert_equal :encounter_not_closable, result.error
        assert_equal "finished", encounter.status
        assert_nil encounter.period_end
      end

      test "finalize refuses already finished encounter when saved coding is unresolved" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090102",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 15,
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(
          status: "finished",
          period_end: nil,
          class_code: "AMB",
          ien: 2_090_102,
          patient_dfn: 8801
        )

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :encounter_not_closable, result.error
        assert_equal "finished", encounter.status
        assert_nil encounter.period_end
      end

      test "finalize refuses already finished encounter when saved coding is resolved" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090103",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(
          status: "finished",
          period_end: nil,
          class_code: "AMB",
          ien: 2_090_103,
          patient_dfn: 8801
        )

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :encounter_not_closable, result.error
        assert_equal "finished", encounter.status
        assert_nil encounter.period_end
      end

      test "finalize refuses cancelled encounter when visit coding is missing" do
        encounter = Encounter.new(
          status: "cancelled",
          class_code: "AMB",
          ien: 2_090_104,
          patient_dfn: 8801
        )

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: nil
        ).finalize

        refute result.success?
        assert_equal :encounter_not_closable, result.error
        assert_equal "cancelled", encounter.status
        assert_nil encounter.period_end
      end
    end
  end
end
