# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class MeasureImportServiceTest < ActiveSupport::TestCase
      setup do
        @service = MeasureImportService.new
        @measures_dir = Lakeraven::EHR::Engine.root.join("config", "measures")

        # Track files created during tests for cleanup
        @created_files = []
      end

      teardown do
        @created_files.each { |f| FileUtils.rm_f(f) }
      end

      # =============================================================================
      # IMPORT FROM RESOURCE
      # =============================================================================

      test "imports a valid FHIR Measure resource" do
        measure_json = build_fhir_measure(id: "test_imported_measure", title: "Test Imported Measure")
        track_measure("test_imported_measure")

        result = @service.import_from_resource(measure_json)

        assert result.success?
        assert_equal "test_imported_measure", result.measure_id
        assert_empty result.errors

        yaml_path = @measures_dir.join("test_imported_measure.yml")
        assert File.exist?(yaml_path), "Expected YAML file at #{yaml_path}"

        measure = Measure.find("test_imported_measure")
        assert_not_nil measure
        assert_equal "Test Imported Measure", measure.title
      end

      test "imports measure with NQF identifier" do
        measure_json = build_fhir_measure(id: "test_nqf_measure", title: "NQF Test", nqf_number: "0059")
        track_measure("test_nqf_measure")

        result = @service.import_from_resource(measure_json)

        assert result.success?
        measure = Measure.find("test_nqf_measure")
        assert_equal "0059", measure.nqf_number
      end

      test "imports measure with scoring type" do
        measure_json = build_fhir_measure(id: "test_scored_measure", title: "Scored Test", scoring: "continuous-variable")
        track_measure("test_scored_measure")

        result = @service.import_from_resource(measure_json)

        assert result.success?
        measure = Measure.find("test_scored_measure")
        assert_equal "continuous-variable", measure.scoring
      end

      test "imports measure with population criteria" do
        measure_json = build_fhir_measure_with_populations(id: "test_pop_measure", title: "Population Test")
        track_measure("test_pop_measure")

        result = @service.import_from_resource(measure_json)

        assert result.success?
        measure = Measure.find("test_pop_measure")
        assert_not_nil measure.initial_population
        assert_not_nil measure.denominator
        assert_not_nil measure.numerator
      end

      test "rejects non-Measure resource" do
        result = @service.import_from_resource({ "resourceType" => "Patient", "id" => "123" })

        assert_not result.success?
        assert_includes result.errors.first, "Expected Measure resourceType"
      end

      test "rejects measure without id or title" do
        result = @service.import_from_resource({ "resourceType" => "Measure" })

        assert_not result.success?
        assert result.errors.any? { |e| e.include?("title is required") }
      end

      test "rejects invalid JSON string" do
        result = @service.import_from_resource("not valid json{{{")

        assert_not result.success?
        assert_includes result.errors, "Invalid JSON"
      end

      test "accepts JSON string input" do
        json_string = build_fhir_measure(id: "test_string_input", title: "String Input Test").to_json
        track_measure("test_string_input")

        result = @service.import_from_resource(json_string)

        assert result.success?
      end

      # =============================================================================
      # IMPORT FROM BUNDLE
      # =============================================================================

      test "imports measures from a FHIR Bundle" do
        bundle = {
          "resourceType" => "Bundle",
          "type" => "collection",
          "entry" => [
            { "resource" => build_fhir_measure(id: "test_bundle_a", title: "Bundle Measure A") },
            { "resource" => build_fhir_measure(id: "test_bundle_b", title: "Bundle Measure B") }
          ]
        }
        track_measure("test_bundle_a")
        track_measure("test_bundle_b")

        results = @service.import_from_bundle(bundle.to_json)

        assert_equal 2, results.length
        assert results.all?(&:success?)
        assert_equal %w[test_bundle_a test_bundle_b], results.map(&:measure_id)
      end

      test "handles Bundle with no Measure entries" do
        bundle = {
          "resourceType" => "Bundle",
          "type" => "collection",
          "entry" => [
            { "resource" => { "resourceType" => "Patient", "id" => "1" } }
          ]
        }

        results = @service.import_from_bundle(bundle.to_json)

        assert_equal 1, results.length
        assert_not results.first.success?
        assert_includes results.first.errors.first, "No Measure resources found"
      end

      test "rejects non-Bundle resource for bundle import" do
        results = @service.import_from_bundle({ "resourceType" => "Measure" }.to_json)

        assert_equal 1, results.length
        assert_not results.first.success?
        assert_includes results.first.errors.first, "Expected Bundle resourceType"
      end

      test "handles invalid JSON in bundle import" do
        results = @service.import_from_bundle("not json")

        assert_equal 1, results.length
        assert_not results.first.success?
      end

      # =============================================================================
      # DATA REQUIREMENTS
      # =============================================================================

      test "returns data requirements for existing measure" do
        requirements = @service.data_requirements("diabetes_a1c_control")

        assert_not_nil requirements
        assert requirements.is_a?(Array)
        assert requirements.any? { |r| %w[Condition Observation Patient].include?(r[:type]) }
      end

      test "returns nil for non-existent measure" do
        assert_nil @service.data_requirements("nonexistent_measure")
      end

      test "data requirements include valueset availability" do
        requirements = @service.data_requirements("diabetes_a1c_control")

        requirements.each do |req|
          assert_includes req.keys, :available
          assert [ true, false ].include?(req[:available])
        end
      end

      # =============================================================================
      # MULTI-VALUESET MEASURES
      # =============================================================================

      test "multi-valueset measure does not assign same valueset to all populations" do
        measure = build_fhir_measure(id: "test_multi_vs", title: "Multi VS Test")
        measure["group"] = [ {
          "population" => [
            {
              "code" => { "coding" => [ { "code" => "initial-population" } ] },
              "criteria" => { "expression" => "Initial Population", "language" => "text/cql" }
            },
            {
              "code" => { "coding" => [ { "code" => "numerator" } ] },
              "criteria" => { "expression" => "Numerator", "language" => "text/cql" }
            }
          ]
        } ]
        measure["relatedArtifact"] = [
          { "type" => "depends-on", "resource" => "http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.464.1003.103.12.1001", "display" => "Initial Population" },
          { "type" => "depends-on", "resource" => "http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113883.3.464.1003.198.12.1013", "display" => "Numerator" }
        ]
        track_measure("test_multi_vs")

        result = @service.import_from_resource(measure)

        assert result.success?
        imported = Measure.find("test_multi_vs")
        ip_vs = imported.initial_population&.dig(:valueset_id) || imported.initial_population&.dig("valueset_id")
        num_vs = imported.numerator&.dig(:valueset_id) || imported.numerator&.dig("valueset_id")
        assert_not_equal ip_vs, num_vs, "Initial population and numerator should have different ValueSets"
      end

      test "unresolvable multi-valueset leaves populations unmapped" do
        measure = build_fhir_measure(id: "test_ambiguous_vs", title: "Ambiguous VS Test")
        measure["group"] = [ {
          "population" => [
            {
              "code" => { "coding" => [ { "code" => "initial-population" } ] },
              "description" => "Some population"
            }
          ]
        } ]
        measure["relatedArtifact"] = [
          { "type" => "depends-on", "resource" => "http://cts.nlm.nih.gov/fhir/ValueSet/AAA" },
          { "type" => "depends-on", "resource" => "http://cts.nlm.nih.gov/fhir/ValueSet/BBB" }
        ]
        track_measure("test_ambiguous_vs")

        result = @service.import_from_resource(measure)

        assert result.success?
        imported = Measure.find("test_ambiguous_vs")
        ip_vs = imported.initial_population&.dig(:valueset_id) || imported.initial_population&.dig("valueset_id")
        assert_nil ip_vs
      end

      # =============================================================================
      # CANONICAL URLS
      # =============================================================================

      test "data requirements return canonical URLs" do
        requirements = @service.data_requirements("diabetes_a1c_control")

        requirements.each do |req|
          assert req[:canonical_url].present?, "Expected canonical_url for #{req[:id]}"
          assert req[:canonical_url].start_with?("http"), "Expected URL format"
        end
      end

      # =============================================================================
      # HELPERS
      # =============================================================================

      private

      def build_fhir_measure(id:, title:, nqf_number: nil, scoring: "proportion")
        measure = {
          "resourceType" => "Measure",
          "id" => id,
          "title" => title,
          "status" => "active",
          "scoring" => {
            "coding" => [ { "system" => "http://terminology.hl7.org/CodeSystem/measure-scoring",
                            "code" => scoring } ]
          }
        }

        if nqf_number
          measure["identifier"] = [ {
            "system" => "http://hl7.org/fhir/cqi/ecqm/Measure/Identifier/nqf",
            "value" => nqf_number
          } ]
        end

        measure
      end

      def build_fhir_measure_with_populations(id:, title:)
        measure = build_fhir_measure(id: id, title: title)
        measure["group"] = [ {
          "population" => [
            {
              "code" => { "coding" => [ { "code" => "initial-population" } ] },
              "description" => "Test initial population"
            },
            {
              "code" => { "coding" => [ { "code" => "denominator" } ] },
              "description" => "Test denominator"
            },
            {
              "code" => { "coding" => [ { "code" => "numerator" } ] },
              "description" => "Test numerator"
            }
          ]
        } ]
        measure
      end

      def track_measure(measure_id)
        @created_files << @measures_dir.join("#{measure_id}.yml").to_s
      end
    end
  end
end
