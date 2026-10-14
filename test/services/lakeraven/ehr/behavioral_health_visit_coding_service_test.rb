# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BehavioralHealthVisitCodingServiceTest < ActiveSupport::TestCase
      INDIVIDUAL = PsychotherapyVisitCodingRules::ENCOUNTER_KIND_INDIVIDUAL_PSYCHOTHERAPY

      class FakeProcedureGateway
        attr_reader :calls

        def initialize
          @calls = []
        end

        def add(dfn, visit_ien, cpt_code, **kwargs)
          @calls << { dfn: dfn, visit_ien: visit_ien, cpt_code: cpt_code, kwargs: kwargs }
          { success: true, ien: 501, raw: "1^501" }
        end
      end

      teardown { BehavioralHealthVisitCoding.delete_all }

      test "save persists resolved coding and returns claim handoff" do
        gateway = FakeProcedureGateway.new
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 38,
          documented_by_duz: "2843",
          procedure_gateway: gateway,
          persist_procedure: true
        ).save

        assert result.success?, result.errors.inspect
        assert_equal "90834", result.record.cpt_code
        assert_equal "90834", result.claim_handoff[:procedure_code]
        assert_equal 38, result.claim_handoff[:duration_minutes]
        assert_equal 1, gateway.calls.length
        assert_equal "90834", gateway.calls.first[:cpt_code]
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
        gateway = FakeProcedureGateway.new
        result = BehavioralHealthVisitCodingService.new(
          patient_dfn: 8801,
          encounter_ien: "2090061",
          encounter_kind: INDIVIDUAL,
          duration_minutes: 45,
          selected_cpt_code: "90834",
          documented_by_duz: "2843",
          procedure_gateway: gateway,
          persist_procedure: true
        ).save

        assert result.success?, result.errors.inspect
        assert_equal "90834", result.record.cpt_code
        assert_equal "90834", result.record.selected_cpt_code
        assert_equal "90834", result.claim_handoff[:procedure_code]
        assert_equal "90834", gateway.calls.first[:cpt_code]
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
    end
  end
end
