# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitGateR2Test < ActiveSupport::TestCase
      EVAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_PSYCHIATRIC_DIAGNOSTIC_EVALUATION
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      PATIENT_DFN = 8802
      ENCOUNTER_IEN = "2090061"
      ENCOUNTER_IEN_INT = 2_090_061
      DOCUMENTED_BY_DUZ = "2843"

      teardown { BehavioralHealthVisitCoding.delete_all }

      def in_progress_encounter(**overrides)
        Encounter.new(
          status: "in-progress",
          class_code: "AMB",
          ien: ENCOUNTER_IEN_INT,
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

      def base_row_attributes(**overrides)
        {
          patient_dfn: PATIENT_DFN,
          encounter_ien: ENCOUNTER_IEN,
          encounter_kind: EVAL,
          duration_minutes: nil,
          documented_by_duz: DOCUMENTED_BY_DUZ,
          cpt_code: "90791"
        }.merge(overrides)
      end

      # A rejected statement aborts the enclosing transaction in Postgres; the
      # savepoint keeps the test transaction (and teardown) usable afterwards.
      def insert_raw(rows)
        BehavioralHealthVisitCoding.transaction(requires_new: true) do
          BehavioralHealthVisitCoding.insert_all(rows)
        end
      end

      def insert_timestamp_attributes
        now = Time.current
        { created_at: now, updated_at: now }
      end

      test "D1 finalize with resolved coding for patient 8802 when in-progress encounter has matching IEN but nil patient_dfn returns coding_encounter_mismatch and leaves encounter in-progress" do
        coding = resolved_saved_coding
        encounter = in_progress_encounter(patient_dfn: nil)

        assert coding.resolved?
        assert_equal PATIENT_DFN, coding.patient_dfn
        assert_nil encounter.patient_dfn

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_encounter_mismatch, result.error
        assert encounter.in_progress?
        refute encounter.finished?
      end

      test "D2 persisted resolved 45-minute coding with unsaved duration 40 yields nil claim handoff and finalize returns coding_unresolved" do
        coding = resolved_saved_coding
        encounter = in_progress_encounter(patient_dfn: PATIENT_DFN)

        coding.duration_minutes = 40

        assert coding.persisted?
        assert coding.resolved?
        assert_nil coding.to_claim_procedure_handoff

        result = BehavioralHealthVisitFinalizationService.new(
          encounter: encounter,
          visit_coding: coding
        ).finalize

        refute result.success?
        assert_equal :coding_unresolved, result.error
        assert encounter.in_progress?
        refute encounter.finished?
      end

      test "D3 raw insert of psychiatric diagnostic evaluation rejects negative duration at the database and accepts nil and zero" do
        assert_raises(ActiveRecord::StatementInvalid) do
          insert_raw(
            [ base_row_attributes(
              encounter_ien: "gate-d3-eval-negative-duration",
              duration_minutes: -5,
              cpt_code: "90791"
            ).merge(insert_timestamp_attributes) ]
          )
        end

        insert_raw(
          [ base_row_attributes(
            encounter_ien: "gate-d3-eval-nil-duration",
            duration_minutes: nil,
            cpt_code: "90791"
          ).merge(insert_timestamp_attributes) ]
        )
        assert_equal 1, BehavioralHealthVisitCoding.where(encounter_ien: "gate-d3-eval-nil-duration").count

        insert_raw(
          [ base_row_attributes(
            encounter_ien: "gate-d3-eval-zero-duration",
            duration_minutes: 0,
            cpt_code: "90791"
          ).merge(insert_timestamp_attributes) ]
        )
        assert_equal 1, BehavioralHealthVisitCoding.where(encounter_ien: "gate-d3-eval-zero-duration").count
      end
    end
  end
end
