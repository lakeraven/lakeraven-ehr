# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MeasureTest < ActiveSupport::TestCase
      # ======================================================================
      # LOADING FROM YAML
      # ======================================================================

      test "Measure.find loads measure from YAML config" do
        measure = Measure.find("diabetes_a1c_control")

        assert_not_nil measure
        assert_equal "diabetes_a1c_control", measure.id
        assert_equal "0059", measure.nqf_number
        assert_equal "proportion", measure.scoring
        assert_includes measure.title, "Diabetes"
      end

      test "Measure.find returns nil for non-existent measure" do
        assert_nil Measure.find("nonexistent_measure")
      end

      test "Measure.all returns all configured measures" do
        measures = Measure.all

        assert measures.length >= 3
        ids = measures.map(&:id)
        assert_includes ids, "diabetes_a1c_control"
        assert_includes ids, "bmi_screening"
        assert_includes ids, "depression_screening"
      end

      test "measure has initial population criteria" do
        measure = Measure.find("diabetes_a1c_control")

        assert_not_nil measure.initial_population
        assert_equal "Condition", measure.initial_population["resource_type"]
        assert_equal "gpra-bgpmu-diabetes-dx", measure.initial_population["valueset_id"]
      end

      test "measure has numerator criteria with value threshold" do
        measure = Measure.find("diabetes_a1c_control")

        assert_not_nil measure.numerator
        assert_equal "Observation", measure.numerator["resource_type"]
        assert_equal "gpra-bgpmu-lab-loinc-hgba1c", measure.numerator["valueset_id"]
        assert_equal "9.0", measure.numerator["value_threshold"].to_s
        assert_equal "<", measure.numerator["value_comparator"]
      end

      test "BMI measure has age-based initial population" do
        measure = Measure.find("bmi_screening")

        assert_equal "Patient", measure.initial_population["resource_type"]
        assert_equal 18, measure.initial_population["min_age"]
      end

      test "BMI measure has code-based numerator" do
        measure = Measure.find("bmi_screening")

        assert_equal "Observation", measure.numerator["resource_type"]
        assert_equal "39156-5", measure.numerator["code"]
      end

      test "depression screening measure has valueset-based numerator" do
        measure = Measure.find("depression_screening")

        assert_equal "Observation", measure.numerator["resource_type"]
        assert_equal "gpra-bgpmu-depression-screening", measure.numerator["valueset_id"]
      end

      # ======================================================================
      # FHIR SERIALIZATION (hash-based)
      # ======================================================================

      test "to_fhir produces valid Measure resource" do
        measure = Measure.find("diabetes_a1c_control")
        fhir = measure.to_fhir

        assert_equal "Measure", fhir[:resourceType]
        assert_equal "diabetes_a1c_control", fhir[:id]
        assert_includes fhir[:title], "Diabetes"
        assert_equal "active", fhir[:status]
        assert_equal "proportion", fhir.dig(:scoring, :coding, 0, :code)
      end

      test "to_fhir includes NQF identifier" do
        measure = Measure.find("diabetes_a1c_control")
        fhir = measure.to_fhir

        assert_not_nil fhir[:identifier]
        assert_equal "0059", fhir[:identifier].first[:value]
      end

      test "to_fhir includes population groups" do
        measure = Measure.find("diabetes_a1c_control")
        fhir = measure.to_fhir

        assert_not_nil fhir[:group]
        group = fhir[:group].first
        population_codes = group[:population].map { |p| p.dig(:code, :coding, 0, :code) }

        assert_includes population_codes, "initial-population"
        assert_includes population_codes, "denominator"
        assert_includes population_codes, "numerator"
      end

      test "as_json produces serializable hash" do
        measure = Measure.find("diabetes_a1c_control")
        json = measure.as_json

        assert_kind_of Hash, json
        assert_equal "Measure", json[:resourceType]
      end

      test "persisted? returns true when id is present" do
        measure = Measure.find("diabetes_a1c_control")
        assert measure.persisted?
      end

      test "persisted? returns false when id is blank" do
        measure = Measure.new
        assert_not measure.persisted?
      end

      # ======================================================================
      # FHIR IMPORT (from_fhir_attributes)
      # ======================================================================

      test "from_fhir_attributes extracts id and title" do
        fhir_resource = {
          "id" => "test_measure",
          "title" => "Test Measure",
          "scoring" => { "coding" => [{ "code" => "proportion" }] }
        }

        attrs = Measure.from_fhir_attributes(fhir_resource)

        assert_equal "test_measure", attrs[:id]
        assert_equal "Test Measure", attrs[:title]
        assert_equal "proportion", attrs[:scoring]
      end

      test "from_fhir_attributes extracts NQF number" do
        fhir_resource = {
          "id" => "test_nqf",
          "title" => "NQF Test",
          "identifier" => [{
            "system" => "http://hl7.org/fhir/cqi/ecqm/Measure/Identifier/nqf",
            "value" => "0059"
          }]
        }

        attrs = Measure.from_fhir_attributes(fhir_resource)

        assert_equal "0059", attrs[:nqf_number]
      end

      test "from_fhir_attributes defaults scoring to proportion" do
        fhir_resource = { "id" => "test_default", "title" => "Default Scoring" }

        attrs = Measure.from_fhir_attributes(fhir_resource)

        assert_equal "proportion", attrs[:scoring]
      end

      test "from_fhir_attributes handles symbol keys for scoring" do
        fhir_resource = {
          id: "test_symbol",
          title: "Symbol Keys",
          scoring: { coding: [{ code: "continuous-variable" }] }
        }

        attrs = Measure.from_fhir_attributes(fhir_resource)

        assert_equal "continuous-variable", attrs[:scoring]
        assert_equal "test_symbol", attrs[:id]
        assert_equal "Symbol Keys", attrs[:title]
      end
    end
  end
end
