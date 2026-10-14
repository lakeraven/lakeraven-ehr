# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitCodingTest < ActiveSupport::TestCase
      EVAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_PSYCHIATRIC_DIAGNOSTIC_EVALUATION
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      teardown { BehavioralHealthVisitCoding.delete_all }

      def attributes(**overrides)
        {
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        }.merge(overrides)
      end

      def build(**overrides) = BehavioralHealthVisitCoding.new(attributes(**overrides))

      test "a resolved individual visit stores the derived CPT code matching documented duration" do
        record = build(duration_minutes: 45)

        assert record.valid?, record.errors.full_messages.inspect
        assert record.resolved?
        assert_equal "90834", record.cpt_code
      end

      test "an individual visit under 16 minutes may be stored but is not resolved and cannot be finalized" do
        record = build(duration_minutes: 15)

        assert record.valid?, record.errors.full_messages.inspect
        refute record.resolved?
        assert record.finalize_blocked?
        assert_equal :below_minimum_duration, record.blocking_reason
        assert_nil record.cpt_code
      end

      test "missing duration on individual psychotherapy is not resolved" do
        record = build(duration_minutes: nil)

        refute record.valid?
        refute record.resolved?
        assert_equal :missing_duration, record.blocking_reason
      end

      test "zero or negative duration is invalid and not resolved" do
        [ 0, -3 ].each do |minutes|
          record = build(duration_minutes: minutes)

          refute record.valid?
          refute record.resolved?
          assert_equal :invalid_duration, record.blocking_reason
        end
      end

      test "psychiatric diagnostic evaluation resolves to 90791 without duration" do
        record = build(encounter_kind: EVAL, duration_minutes: nil)

        assert record.valid?, record.errors.full_messages.inspect
        assert record.resolved?
        assert_equal "90791", record.cpt_code
        refute record.finalize_blocked?
      end

      test "claim handoff exposes procedure code and documented duration only" do
        record = build(duration_minutes: 53)
        record.validate

        handoff = record.to_claim_procedure_handoff

        assert_equal "90837", handoff[:procedure_code]
        assert_equal 53, handoff[:duration_minutes]
        assert_equal Procedure::CODE_SYSTEM_URLS["cpt"], handoff[:code_system]
        refute handoff.key?(:diagnosis_code)
        refute handoff.key?(:diagnosis_codes)
        refute handoff.key?(:icd10)
      end

      test "unresolved coding produces no claim handoff" do
        record = build(duration_minutes: 15)

        assert_nil record.to_claim_procedure_handoff
      end

      test "clinician selection inconsistent with documented duration is stored but not resolved" do
        record = build(duration_minutes: 30, selected_cpt_code: "90837")

        assert record.valid?, record.errors.full_messages.inspect
        refute record.resolved?
        assert record.finalize_blocked?
        assert_equal :selection_inconsistent_with_duration, record.blocking_reason
        assert_nil record.cpt_code
      end

      test "consistent clinician selection resolves to the selected code for claims" do
        record = build(duration_minutes: 45, selected_cpt_code: "90834")

        assert record.valid?, record.errors.full_messages.inspect
        assert record.resolved?
        assert_equal "90834", record.cpt_code
        assert_equal "90834", record.to_claim_procedure_handoff[:procedure_code]
        assert_equal 45, record.to_claim_procedure_handoff[:duration_minutes]
      end

      test "disallowed clinician-selected CPT is refused at validation" do
        record = build(duration_minutes: 45, selected_cpt_code: "99213")

        refute record.valid?
        refute record.resolved?
        assert_equal :disallowed_cpt_code, record.blocking_reason
      end

      test "90791 selected on individual psychotherapy is refused at validation" do
        record = build(encounter_kind: INDIVIDUAL, duration_minutes: 45, selected_cpt_code: "90791")

        refute record.valid?
        refute record.resolved?
        assert_equal :cpt_code_incompatible_with_encounter_kind, record.blocking_reason
      end

      test "individual psychotherapy with selected code but missing duration is never resolved" do
        record = build(duration_minutes: nil, selected_cpt_code: "90834")

        refute record.valid?
        refute record.resolved?
        assert_equal :missing_duration, record.blocking_reason
      end
    end
  end
end
