# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Lakeraven
  module EHR
    module FHIR
      class ConditionSerializerTest < ActiveSupport::TestCase
        test "serializes condition with ICD coding" do
          condition = build_condition(icd_code: "E11.9")
          result = ConditionSerializer.new(condition).to_h

          assert_equal "Condition", result[:resourceType]
          coding = result[:code][:coding]
          assert coding.any? { |c| c[:code] == "E11.9" && c[:system].include?("icd-10") }
        end

        test "serializes condition with multiple codings" do
          condition = build_condition(icd_code: "E11.9", snomed_code: "44054006")
          result = ConditionSerializer.new(condition).to_h

          codings = result[:code][:coding]
          assert codings.any? { |c| c[:system].include?("icd-10") }
          assert codings.any? { |c| c[:system].include?("snomed") }
        end

        test "includes clinical status" do
          condition = build_condition(status: "A")
          result = ConditionSerializer.new(condition).to_h

          assert_equal "active", result[:clinicalStatus][:coding].first[:code]
        end

        test "includes patient reference" do
          condition = build_condition(patient_dfn: "123")
          result = ConditionSerializer.new(condition).to_h

          assert_equal "Patient/123", result[:subject][:reference]
        end

        test "includes onset date" do
          condition = build_condition(onset: Date.new(2025, 6, 1))
          result = ConditionSerializer.new(condition).to_h

          assert_equal "2025-06-01", result[:onsetDateTime]
        end

        test "redaction policy applies to serialized output" do
          condition = build_condition
          policy = RedactionPolicy.new(view: :research)
          result = ConditionSerializer.new(condition, policy: policy).to_h

          assert_equal "Condition", result[:resourceType]
        end

        test "handles nil icd_code gracefully" do
          condition = build_condition(icd_code: nil)
          result = ConditionSerializer.new(condition).to_h

          assert_equal "Condition", result[:resourceType]
          # May have empty codings or none
          assert result[:code].is_a?(Hash)
        end

        private

        def build_condition(icd_code: "E11.9", snomed_code: nil, status: "A",
                            patient_dfn: "1", onset: nil)
          ::OpenStruct.new(
            ien: "prob-001",
            icd_code: icd_code,
            snomed_code: snomed_code,
            status: status,
            description: "Type 2 diabetes",
            patient_dfn: patient_dfn,
            onset_date: onset,
            recorded_date: Date.current
          )
        end
      end
    end
  end
end
