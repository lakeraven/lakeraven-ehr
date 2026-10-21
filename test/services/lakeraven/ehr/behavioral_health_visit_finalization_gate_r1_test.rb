# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitFinalizationGateR1Test < ActiveSupport::TestCase
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      PATIENT_DFN = 8801
      ENCOUNTER_IEN = "2090061"
      ENCOUNTER_IEN_INT = 2_090_061
      DOCUMENTED_BY_DUZ = "2843"

      teardown { BehavioralHealthVisitCoding.delete_all }

      def in_progress_encounter(**overrides)
        Encounter.new(
          status: "in-progress",
          class_code: "AMB",
          ien: ENCOUNTER_IEN_INT,
          patient_dfn: PATIENT_DFN,
          **overrides
        )
      end

      def resolved_saved_coding(**overrides)
        BehavioralHealthVisitCoding.create!(
          patient_dfn: PATIENT_DFN,
          encounter_ien: ENCOUNTER_IEN,
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: DOCUMENTED_BY_DUZ,
          **overrides
        )
      end

      test "B1 finalize with resolved saved coding whose encounter_ien differs from the encounter returns coding_encounter_mismatch and leaves encounter in-progress" do
        coding = resolved_saved_coding(encounter_ien: "2090999")
        encounter = in_progress_encounter

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_encounter_mismatch, result.error
        assert encounter.in_progress?
        refute encounter.finished?
      end

      test "B1 finalize with resolved saved coding whose patient_dfn differs from the encounter returns coding_encounter_mismatch and leaves encounter in-progress" do
        coding = resolved_saved_coding(patient_dfn: 8802)
        encounter = in_progress_encounter(patient_dfn: PATIENT_DFN)

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_encounter_mismatch, result.error
        assert encounter.in_progress?
        refute encounter.finished?
      end

      test "B2 finalize with unsaved resolved individual 45-minute coding returns coding_not_recorded and leaves encounter in-progress with no claim handoff" do
        encounter = in_progress_encounter
        coding = BehavioralHealthVisitCoding.new(
          patient_dfn: PATIENT_DFN,
          encounter_ien: ENCOUNTER_IEN,
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: DOCUMENTED_BY_DUZ
        )

        assert coding.new_record?
        assert coding.resolved?

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_not_recorded, result.error
        assert encounter.in_progress?
        refute encounter.finished?
        assert_nil coding.to_claim_procedure_handoff
      end

      test "B3 second BehavioralHealthVisitCodingService save for the same patient_dfn and encounter_ien returns coding_already_recorded with exactly one row" do
        service_attrs = {
          patient_dfn: PATIENT_DFN,
          encounter_ien: ENCOUNTER_IEN,
          encounter_kind: INDIVIDUAL,
          duration_minutes: 38,
          documented_by_duz: DOCUMENTED_BY_DUZ
        }

        first = BehavioralHealthVisitCodingService.new(**service_attrs).save
        assert first.success?, first.errors.inspect
        assert_equal 1, BehavioralHealthVisitCoding.count

        second = BehavioralHealthVisitCodingService.new(**service_attrs.merge(duration_minutes: 45)).save

        refute second.success?
        assert_equal :coding_already_recorded, second.error
        assert_equal 1, BehavioralHealthVisitCoding.count
      end

      test "B5 finalize with resolved matching saved coding on an already finished encounter returns encounter_not_closable" do
        coding = resolved_saved_coding
        encounter = Encounter.new(
          status: "finished",
          class_code: "AMB",
          ien: ENCOUNTER_IEN_INT,
          patient_dfn: PATIENT_DFN
        )

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :encounter_not_closable, result.error
        refute_equal :coding_unresolved, result.error
        assert encounter.finished?
      end

      test "B7 BehavioralHealthVisitCodingService save with unknown encounter_kind foo returns unknown_encounter_kind and stores nothing" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: PATIENT_DFN,
          encounter_ien: ENCOUNTER_IEN,
          encounter_kind: "foo",
          duration_minutes: 45,
          documented_by_duz: DOCUMENTED_BY_DUZ
        ).save

        refute result.success?
        assert_equal :unknown_encounter_kind, result.error
        assert_equal 0, BehavioralHealthVisitCoding.count
      end
    end
  end
end
