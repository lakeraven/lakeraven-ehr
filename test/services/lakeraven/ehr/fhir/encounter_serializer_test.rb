# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    module FHIR
      class EncounterSerializerTest < ActiveSupport::TestCase
        test "serializes resourceType and id" do
          result = serialize(build_encounter)

          assert_equal "Encounter", result[:resourceType]
          assert_equal "42", result[:id]
        end

        test "includes status" do
          result = serialize(build_encounter(status: "in-progress"))

          assert_equal "in-progress", result[:status]
        end

        test "includes class coding" do
          result = serialize(build_encounter(class_code: "AMB"))

          assert_equal "AMB", result[:class][:code]
        end

        test "includes subject patient reference" do
          result = serialize(build_encounter(patient_identifier: "123"))

          assert_equal "Patient/123", result[:subject][:reference]
        end

        test "includes period with start and end" do
          result = serialize(build_encounter(
            period_start: DateTime.new(2024, 1, 15, 9, 0),
            period_end: DateTime.new(2024, 1, 15, 10, 30)
          ))

          refute_nil result[:period]
          refute_nil result[:period][:start]
          refute_nil result[:period][:end]
        end

        test "includes type when present" do
          result = serialize(build_encounter(type_code: "WELLNESS", type_display: "Wellness Visit"))

          refute_nil result[:type]
          assert result[:type].any? { |t| t[:coding].any? { |c| c[:code] == "WELLNESS" } }
        end

        test "includes reason when present" do
          result = serialize(build_encounter(reason_code: "CHECKUP", reason_display: "Annual checkup"))

          refute_nil result[:reasonCode]
        end

        test "includes location when present" do
          result = serialize(build_encounter(location_ien: 100))

          refute_nil result[:location]
          assert result[:location].any? { |l| l[:location][:reference].include?("100") }
        end

        test "handles minimal encounter" do
          enc = Encounter.new(ien: 1, status: "finished", patient_identifier: "1")
          result = EncounterSerializer.new(enc).to_h

          assert_equal "Encounter", result[:resourceType]
          assert_equal "finished", result[:status]
        end

        test "redaction policy applies" do
          result = serialize(build_encounter)
          policy = RedactionPolicy.new(view: :full)
          redacted = policy.apply(result)

          assert_equal "Encounter", redacted[:resourceType]
        end

        private

        def build_encounter(attrs = {})
          defaults = {
            ien: 42, status: "in-progress", patient_identifier: "1",
            class_code: "AMB", period_start: DateTime.new(2024, 1, 15, 9, 0),
            period_end: DateTime.new(2024, 1, 15, 10, 30)
          }
          Encounter.new(defaults.merge(attrs))
        end

        def serialize(encounter)
          EncounterSerializer.new(encounter).to_h
        end
      end
    end
  end
end
