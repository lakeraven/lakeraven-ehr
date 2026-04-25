# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientUsCoreTest < ActiveSupport::TestCase
      # =============================================================================
      # US Core Patient Profile Compliance (ported from rpms_redux)
      # =============================================================================

      test "to_fhir includes meta.profile with us-core-patient URL" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        fhir = patient.to_fhir

        assert_includes fhir.dig(:meta, :profile),
                        "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
      end

      # =============================================================================
      # US Core Race Extension
      # =============================================================================

      test "to_fhir includes US Core race extension with ombCategory coding for known race" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M", race: "AMERICAN INDIAN OR ALASKA NATIVE")
        fhir = patient.to_fhir

        race_ext = fhir[:extension].find { |e| e[:url] == "http://hl7.org/fhir/us/core/StructureDefinition/us-core-race" }
        assert_not_nil race_ext, "Expected us-core-race extension"

        omb_sub = race_ext[:extension].find { |e| e[:url] == "ombCategory" }
        assert_not_nil omb_sub, "Expected ombCategory sub-extension"
        assert_equal "1002-5", omb_sub[:valueCoding][:code]
        assert_equal "urn:oid:2.16.840.1.113883.6.238", omb_sub[:valueCoding][:system]

        text_sub = race_ext[:extension].find { |e| e[:url] == "text" }
        assert_not_nil text_sub, "Expected text sub-extension"
        assert_equal "American Indian or Alaska Native", text_sub[:valueString]
      end

      test "to_fhir includes US Core race extension with text only for unknown race" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M", race: "MULTIRACIAL")
        fhir = patient.to_fhir

        race_ext = fhir[:extension].find { |e| e[:url] == "http://hl7.org/fhir/us/core/StructureDefinition/us-core-race" }
        assert_not_nil race_ext, "Expected us-core-race extension"

        omb_sub = race_ext[:extension].find { |e| e[:url] == "ombCategory" }
        assert_nil omb_sub, "Expected no ombCategory for unmapped race"

        text_sub = race_ext[:extension].find { |e| e[:url] == "text" }
        assert_not_nil text_sub, "Expected text sub-extension"
        assert_equal "MULTIRACIAL", text_sub[:valueString]
      end

      # =============================================================================
      # US Core Ethnicity Extension
      # =============================================================================

      test "to_fhir includes US Core ethnicity extension" do
        patient = Patient.new(dfn: 1, name: "DOE,JOHN", sex: "M")
        fhir = patient.to_fhir

        eth_ext = fhir[:extension].find { |e| e[:url] == "http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity" }
        assert_not_nil eth_ext, "Expected us-core-ethnicity extension"

        text_sub = eth_ext[:extension].find { |e| e[:url] == "text" }
        assert_not_nil text_sub, "Expected text sub-extension"
        assert_equal "Unknown", text_sub[:valueString]
      end

      # =============================================================================
      # RACE_CODE_MAP completeness
      # =============================================================================

      test "RACE_CODE_MAP maps all expected race values" do
        expected_races = [
          "AMERICAN INDIAN OR ALASKA NATIVE",
          "AMERICAN INDIAN",
          "ALASKA NATIVE",
          "ASIAN",
          "BLACK OR AFRICAN AMERICAN",
          "BLACK",
          "NATIVE HAWAIIAN OR OTHER PACIFIC ISLANDER",
          "WHITE",
          "OTHER",
          "UNKNOWN"
        ]

        expected_races.each do |race|
          mapping = FHIR::PatientSerializer::RACE_CODE_MAP[race]
          assert_not_nil mapping, "Expected RACE_CODE_MAP to include '#{race}'"
          assert mapping[:code].present?, "Expected code for '#{race}'"
          assert mapping[:display].present?, "Expected display for '#{race}'"
        end
      end
    end
  end
end
