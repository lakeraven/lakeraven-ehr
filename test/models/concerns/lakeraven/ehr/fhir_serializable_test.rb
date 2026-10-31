# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class FhirSerializableTest < ActiveSupport::TestCase
      # Host class exposes private FhirSerializable helpers for contract tests.
      class HelperHost
        include Lakeraven::EHR::FhirSerializable

        def call_build_identifier(**kwargs) = build_identifier(**kwargs)
        def call_build_reference(resource_type, id) = build_reference(resource_type, id)
        def call_build_codeable_concept(**kwargs) = build_codeable_concept(**kwargs)
        def call_build_period(**kwargs) = build_period(**kwargs)
      end

      setup do
        @host = HelperHost.new
      end

      test "build_identifier returns system and stringified value" do
        assert_equal(
          { system: "http://example.org/id", value: "42" },
          @host.call_build_identifier(system: "http://example.org/id", value: 42)
        )
      end

      test "build_identifier returns nil when value is nil" do
        assert_nil @host.call_build_identifier(system: "http://example.org/id", value: nil)
      end

      test "build_identifier returns nil when system is nil" do
        assert_nil @host.call_build_identifier(system: nil, value: "42")
      end

      test "build_reference returns FHIR reference hash" do
        assert_equal(
          { reference: "Patient/1" },
          @host.call_build_reference("Patient", 1)
        )
      end

      test "build_reference returns nil when id is nil" do
        assert_nil @host.call_build_reference("Patient", nil)
      end

      test "build_codeable_concept returns coding and text when all parts present" do
        assert_equal(
          {
            coding: [
              {
                system: "http://snomed.info/sct",
                code: "123",
                display: "Example display"
              }
            ],
            text: "Example display"
          },
          @host.call_build_codeable_concept(
            system: "http://snomed.info/sct",
            code: "123",
            display: "Example display"
          )
        )
      end

      test "build_codeable_concept omits nil system and display keys from coding entry" do
        assert_equal(
          { coding: [ { code: "123" } ] },
          @host.call_build_codeable_concept(system: nil, code: "123", display: nil)
        )
      end

      test "build_codeable_concept omits text when display is nil" do
        assert_equal(
          { coding: [ { system: "http://example.org", code: "abc" } ] },
          @host.call_build_codeable_concept(system: "http://example.org", code: "abc", display: nil)
        )
      end

      test "build_codeable_concept returns nil when code is nil" do
        assert_nil @host.call_build_codeable_concept(system: "http://example.org", code: nil, display: "Text")
      end

      test "build_period returns nil when both start and end are nil" do
        assert_nil @host.call_build_period(start_date: nil, end_date: nil)
      end

      test "build_period compacts absent ends and serializes Date as ISO8601 date" do
        assert_equal(
          { start: "2025-01-01" },
          @host.call_build_period(start_date: Date.new(2025, 1, 1), end_date: nil)
        )
      end

      test "build_period serializes Time values as ISO8601 timestamps" do
        start = Time.utc(2024, 6, 1, 10, 0, 0)
        finish = Time.utc(2024, 6, 1, 11, 0, 0)

        assert_equal(
          { start: "2024-06-01T10:00:00Z", end: "2024-06-01T11:00:00Z" },
          @host.call_build_period(start_date: start, end_date: finish)
        )
      end

      test "build_period parses String dates to ISO8601" do
        assert_equal(
          { start: "2024-03-15T14:30:00Z" },
          @host.call_build_period(start_date: "2024-03-15T14:30:00Z", end_date: nil)
        )
      end
    end
  end
end
