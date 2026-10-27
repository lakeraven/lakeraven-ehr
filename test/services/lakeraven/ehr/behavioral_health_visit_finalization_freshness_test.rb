# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitFinalizationFreshnessTest < ActiveSupport::TestCase
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      teardown { BehavioralHealthVisitCoding.delete_all }

      test "finalize refuses cancelled encounter with resolved saved coding" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090091",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(status: "cancelled", class_code: "AMB", ien: 2_090_091, patient_dfn: 8801)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :encounter_not_closable, result.error
        assert_equal "cancelled", encounter.status
        assert_nil encounter.period_end
      end

      test "finalize refuses entered-in-error encounter with resolved saved coding" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090092",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(
          status: "entered-in-error",
          class_code: "AMB",
          ien: 2_090_092,
          patient_dfn: 8801
        )

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :encounter_not_closable, result.error
        assert_equal "entered-in-error", encounter.status
        assert_nil encounter.period_end
      end

      test "finalize succeeds for in-progress encounter with resolved saved coding" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090093",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_093, patient_dfn: 8801)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        assert result.success?
        assert encounter.finished?
      end

      test "finalize refuses when stored coding became unresolved after caller loaded coding" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090094",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        stored = BehavioralHealthVisitCoding.find(coding.id)
        stored.update!(duration_minutes: 15)
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_094, patient_dfn: 8801)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_unresolved, result.error
        refute encounter.finished?
      end

      test "finalize refuses when stored coding resolved differently than caller saw" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090095",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        stored = BehavioralHealthVisitCoding.find(coding.id)
        stored.update!(duration_minutes: 60)
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_095, patient_dfn: 8801)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_stale, result.error
        refute encounter.finished?
      end

      test "finalize refuses when stored coding row was deleted after caller loaded coding" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090096",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        BehavioralHealthVisitCoding.where(id: coding.id).delete_all
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_096, patient_dfn: 8801)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_not_recorded, result.error
        refute encounter.finished?
      end

      test "finalize succeeds when stored coding matches caller-loaded coding" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090097",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_097, patient_dfn: 8801)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        assert result.success?
        assert encounter.finished?
      end

      test "finalize refuses when passed coding has unsaved local edits" do
        coding = BehavioralHealthVisitCoding.create!(
          patient_dfn: 8801,
          encounter_ien: "2090098",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        )
        coding.duration_minutes = 60
        encounter = Encounter.new(status: "in-progress", class_code: "AMB", ien: 2_090_098, patient_dfn: 8801)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        refute encounter.finished?
      end
    end
  end
end
