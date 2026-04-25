# frozen_string_literal: true

module Lakeraven
  module EHR
    # MeasureImportService - FHIR Measure Bundle Import
    #
    # Imports CQM definitions from FHIR Measure resources and saves them as
    # YAML config files compatible with the Measure model.
    #
    # ONC 170.315(c)(2) - Clinical quality measure import
    class MeasureImportService
      VSAC_VALUESET_BASE = ENV.fetch("VSAC_VALUESET_BASE", "http://cts.nlm.nih.gov/fhir/ValueSet")
      IHS_VALUESET_BASE = ENV.fetch("IHS_FHIR_VALUESET_BASE", "https://ihs.gov/fhir/ValueSet")

      ImportResult = Struct.new(:success, :measure_id, :errors, keyword_init: true) do
        def success? = success
      end

      class InvalidMeasureError < StandardError; end

      def initialize(terminology_service: nil, vsac_client: nil)
        @terminology_service = terminology_service
        @vsac_client = vsac_client
      end

      # Import measures from a FHIR Bundle containing Measure resources
      def import_from_bundle(json_string)
        bundle = parse_json(json_string)
        return [ ImportResult.new(success: false, errors: [ "Invalid JSON" ]) ] unless bundle

        unless bundle["resourceType"] == "Bundle"
          return [ ImportResult.new(success: false, errors: [ "Expected Bundle resourceType, got: #{bundle['resourceType']}" ]) ]
        end

        entries = bundle["entry"] || []
        measures = entries.filter_map { |e| e["resource"] }
                          .select { |r| r["resourceType"] == "Measure" }

        if measures.empty?
          return [ ImportResult.new(success: false, errors: [ "No Measure resources found in Bundle" ]) ]
        end

        measures.map { |m| import_from_resource(m) }
      end

      # Import a single FHIR Measure resource
      def import_from_resource(resource)
        resource = parse_json(resource) if resource.is_a?(String)
        return ImportResult.new(success: false, errors: [ "Invalid JSON" ]) unless resource

        unless resource["resourceType"] == "Measure"
          return ImportResult.new(success: false, errors: [ "Expected Measure resourceType, got: #{resource['resourceType']}" ])
        end

        measure_data = extract_measure_data(resource)
        errors = validate_measure_data(measure_data)
        return ImportResult.new(success: false, measure_id: measure_data[:id], errors: errors) if errors.any?

        save_measure_yaml(measure_data)
        resolve_valuesets(measure_data)

        ImportResult.new(success: true, measure_id: measure_data[:id], errors: [])
      rescue StandardError => e
        ImportResult.new(success: false, errors: [ "Import failed: #{e.message}" ])
      end

      # Resolve $data-requirements for a measure
      def data_requirements(measure_id)
        measure = Measure.find(measure_id)
        return nil unless measure

        seen = Set.new
        requirements = []

        [ measure.initial_population, measure.denominator, measure.numerator, measure.denominator_exclusion ].compact.each do |criteria|
          criteria = criteria.is_a?(Hash) ? criteria.deep_symbolize_keys : criteria
          vs_id = criteria[:valueset_id]
          next if vs_id.blank? || seen.include?(vs_id)

          seen << vs_id
          requirements << {
            type: criteria[:resource_type] || "Condition",
            id: vs_id,
            canonical_url: criteria[:canonical_url] || resolve_canonical_url(vs_id),
            available: valueset_available?(vs_id)
          }
        end

        requirements
      end

      private

      def parse_json(input)
        return input if input.is_a?(Hash)

        JSON.parse(input)
      rescue JSON::ParserError
        nil
      end

      def extract_measure_data(resource)
        {
          id: derive_measure_id(resource),
          title: resource["title"] || resource["name"],
          nqf_number: extract_nqf_number(resource),
          scoring: extract_scoring(resource),
          initial_population: extract_population(resource, "initial-population"),
          denominator: extract_population(resource, "denominator"),
          numerator: extract_population(resource, "numerator"),
          denominator_exclusion: extract_population(resource, "denominator-exclusion")
        }
      end

      def derive_measure_id(resource)
        id = resource["id"] || resource["name"] || resource["title"]
        id.to_s.parameterize(separator: "_")
      end

      def extract_nqf_number(resource)
        identifiers = resource["identifier"] || []
        nqf = identifiers.find { |i| i["system"]&.include?("nqf") }
        nqf&.dig("value")
      end

      def extract_scoring(resource)
        resource.dig("scoring", "coding")&.first&.dig("code") || "proportion"
      end

      def extract_population(resource, population_code)
        groups = resource["group"] || []
        return nil if groups.empty?

        group = groups.first
        populations = group["population"] || []

        pop = populations.find do |p|
          codings = p.dig("code", "coding") || []
          codings.any? { |c| c["code"] == population_code }
        end
        return nil unless pop

        description = pop.dig("criteria", "language") == "text/cql" ? pop.dig("criteria", "expression") : pop["description"]

        result = { description: description || pop_display(population_code) }

        valueset_ref = extract_valueset_from_criteria(pop, resource)
        if valueset_ref
          result[:resource_type] = valueset_ref[:resource_type] || "Condition"
          result[:valueset_id] = valueset_ref[:valueset_id]
          result[:canonical_url] = valueset_ref[:canonical_url] if valueset_ref[:canonical_url]
        end

        result
      end

      def extract_valueset_from_criteria(population, resource)
        extensions = population["extension"] || []
        vs_ext = extensions.find { |e| e["url"]&.include?("data-requirement") }
        if vs_ext
          valueset_url = vs_ext.dig("valueCodeableConcept", "coding")&.first&.dig("system")
          return { valueset_id: extract_valueset_id(valueset_url), canonical_url: valueset_url } if valueset_url
        end

        criteria_ref = population.dig("criteria", "expression")
        related = resource["relatedArtifact"] || []
        vs_artifacts = related.select { |a| a["type"] == "depends-on" && a["resource"]&.include?("ValueSet") }

        if criteria_ref.present? && vs_artifacts.size > 1
          matched = vs_artifacts.find { |a| a["display"]&.include?(criteria_ref) || a["resource"]&.include?(criteria_ref) }
          if matched
            url = matched["resource"]
            return { valueset_id: extract_valueset_id(url), canonical_url: url }
          end
        end

        if vs_artifacts.size == 1
          url = vs_artifacts.first["resource"]
          return { valueset_id: extract_valueset_id(url), canonical_url: url }
        end

        nil
      end

      def extract_valueset_id(url)
        return url unless url
        url.split("/").last
      end

      def pop_display(code)
        {
          "initial-population" => "Initial Population",
          "denominator" => "Denominator",
          "numerator" => "Numerator",
          "denominator-exclusion" => "Denominator Exclusion"
        }[code] || code.titleize
      end

      def validate_measure_data(data)
        errors = []
        errors << "Measure id is required" if data[:id].blank?
        errors << "Measure title is required" if data[:title].blank?
        errors
      end

      def save_measure_yaml(data)
        yaml_data = {
          "id" => data[:id],
          "title" => data[:title],
          "nqf_number" => data[:nqf_number],
          "scoring" => data[:scoring] || "proportion"
        }

        [ :initial_population, :denominator, :numerator, :denominator_exclusion ].each do |key|
          criteria = data[key]
          yaml_data[key.to_s] = criteria.transform_keys(&:to_s) if criteria
        end

        filepath = measures_path.join("#{data[:id]}.yml")
        File.write(filepath, YAML.dump(yaml_data))
      end

      def resolve_valuesets(data)
        valueset_ids = [ :initial_population, :denominator, :numerator, :denominator_exclusion ]
          .filter_map { |key| data.dig(key, :valueset_id) }
          .uniq

        valueset_ids.each do |vs_id|
          next if valueset_available?(vs_id)
          # ValueSet fetching from external sources (VSAC) deferred
        end
      end

      def resolve_canonical_url(valueset_id)
        if valueset_id.match?(/^\d+\.\d+/)
          "#{VSAC_VALUESET_BASE}/#{valueset_id}"
        else
          "#{IHS_VALUESET_BASE}/#{valueset_id}"
        end
      end

      def safe_valueset_id(valueset_id)
        id = valueset_id.to_s
        raise ArgumentError, "Invalid valueset_id format: #{id}" unless id.match?(/\A[A-Za-z0-9._-]+\z/)
        id
      end

      def valueset_available?(valueset_id)
        safe_id = safe_valueset_id(valueset_id)
        # Check both engine and additional paths
        valueset_paths.any? { |path| File.exist?(path.join("#{safe_id}.json")) }
      end

      def valueset_paths
        paths = [ Lakeraven::EHR::Engine.root.join("db", "valuesets") ]
        if TerminologyService.respond_to?(:additional_valueset_paths)
          paths.concat(TerminologyService.additional_valueset_paths.map { |p| Pathname.new(p) })
        end
        paths.select { |p| p.exist? rescue false }
      end

      def measures_path
        Lakeraven::EHR::Engine.root.join("config", "measures")
      end
    end
  end
end
