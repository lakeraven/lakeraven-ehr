# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitCodingServiceTest < ActiveSupport::TestCase
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      teardown { BehavioralHealthVisitCoding.delete_all }

      test "save persists resolved coding and returns claim handoff" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 38,
          documented_by_duz: "2843"
        ).save

        assert result.success?, result.errors.inspect
        assert result.record.persisted?
        assert_equal 1, BehavioralHealthVisitCoding.count
        assert_equal "90834", result.record.cpt_code
        assert_equal "90834", result.claim_handoff[:procedure_code]
        assert_equal 38, result.claim_handoff[:duration_minutes]
      end

      test "save does not write procedure to RPMS" do
        rpms_calls = []
        original = ProcedureGateway.method(:add)
        ProcedureGateway.define_singleton_method(:add) do |*args, **kwargs|
          rpms_calls << { args: args, kwargs: kwargs }
          { success: true, ien: 501 }
        end

        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 38,
          documented_by_duz: "2843"
        ).save

        assert result.success?, result.errors.inspect
        assert_empty rpms_calls, "visit coding save must not call ProcedureGateway.add"
      ensure
        ProcedureGateway.define_singleton_method(:add, original)
      end

      test "save refuses unresolved duration without persisting" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: nil,
          documented_by_duz: "2843"
        ).save

        refute result.success?
        assert_equal :missing_duration, result.error
        assert_equal 0, BehavioralHealthVisitCoding.count
      end

      test "save persists resolved coding when clinician selection matches documented duration" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          selected_cpt_code: "90834",
          documented_by_duz: "2843"
        ).save

        assert result.success?, result.errors.inspect
        assert result.record.persisted?
        assert_equal 1, BehavioralHealthVisitCoding.count
        assert_equal "90834", result.record.cpt_code
        assert_equal "90834", result.record.selected_cpt_code
        assert_equal "90834", result.claim_handoff[:procedure_code]
        assert_equal 45, result.claim_handoff[:duration_minutes]
      end

      test "save refuses inconsistent clinician selection without persisting" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 30,
          selected_cpt_code: "90837",
          documented_by_duz: "2843"
        ).save

        refute result.success?
        assert_equal :selection_inconsistent_with_duration, result.error
        assert_equal 0, BehavioralHealthVisitCoding.count
      end

      test "save refuses disallowed clinician-selected CPT without persisting" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          selected_cpt_code: "90853",
          documented_by_duz: "2843"
        ).save

        refute result.success?
        assert_equal :disallowed_cpt_code, result.error
        assert_equal 0, BehavioralHealthVisitCoding.count
      end

      test "save refuses 90791 selected on individual psychotherapy without persisting" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          selected_cpt_code: "90791",
          documented_by_duz: "2843"
        ).save

        refute result.success?
        assert_equal :cpt_code_incompatible_with_encounter_kind, result.error
        assert_equal 0, BehavioralHealthVisitCoding.count
      end

      test "save refuses nonsensical individual psychotherapy duration without persisting or claim handoff" do
        [ "45junk", 45.9, "45.9", "" ].each do |duration|
          result = BehavioralHealthVisitCodingService.new(
            patient_dfn: 8801,
            encounter_ien: "2090061",
            encounter_kind: INDIVIDUAL,
            duration_minutes: duration,
            documented_by_duz: "2843"
          ).save

          refute result.success?, "expected refusal for duration #{duration.inspect}"
          assert_equal :invalid_duration, result.error
          assert_nil result.claim_handoff
          assert_equal 0, BehavioralHealthVisitCoding.count
        end
      end

      test "save accepts integer and string whole-minute duration for individual psychotherapy" do
        # One encounter per case: 45 and "45" would otherwise share an encounter IEN.
        [ [ 45, "2090071" ], [ "45", "2090072" ] ].each do |duration, encounter_ien|
          result = BehavioralHealthVisitCodingService.new(
            patient_dfn: 8801,
            encounter_ien: encounter_ien,
            encounter_kind: INDIVIDUAL,
            duration_minutes: duration,
            documented_by_duz: "2843"
          ).save

          assert result.success?, "expected success for duration #{duration.inspect}: #{result.errors.inspect}"
          assert result.record.persisted?
          assert_equal "90834", result.record.cpt_code
          assert_equal "90834", result.claim_handoff[:procedure_code]
          assert_equal 45, result.claim_handoff[:duration_minutes]
        end
      end

      test "save refuses missing patient_dfn with invalid_input and model validation errors" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: nil,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        ).save

        refute result.success?
        assert_equal :invalid_input, result.error
        assert result.errors.present?, result.errors.inspect
        assert_includes result.errors, "Patient dfn can't be blank"
        assert_equal 0, BehavioralHealthVisitCoding.count
      end

      test "save refuses missing encounter_ien with invalid_input and model validation errors" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: nil,
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: "2843"
        ).save

        refute result.success?
        assert_equal :invalid_input, result.error
        assert result.errors.present?, result.errors.inspect
        assert_includes result.errors, "Encounter ien can't be blank"
        assert_equal 0, BehavioralHealthVisitCoding.count
      end

      test "save refuses missing documented_by_duz with invalid_input and model validation errors" do
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          documented_by_duz: nil
        ).save

        refute result.success?
        assert_equal :invalid_input, result.error
        assert result.errors.present?, result.errors.inspect
        assert_includes result.errors, "Documented by duz can't be blank"
        assert_equal 0, BehavioralHealthVisitCoding.count
      end
    end
  end
end
