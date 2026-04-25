# frozen_string_literal: true

module Lakeraven
  module EHR
    class Measure
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :id, :string
      attribute :title, :string
      attribute :nqf_number, :string
      attribute :scoring, :string

      attr_accessor :initial_population, :denominator, :numerator, :denominator_exclusion

      MEASURES_PATH = File.expand_path("../../../../config/measures", __dir__)

      def self.find(id)
        file = File.join(MEASURES_PATH, "#{id}.yml")
        return nil unless File.exist?(file)

        load_from_yaml(file)
      end

      def self.all
        Dir[File.join(MEASURES_PATH, "*.yml")].map { |f| load_from_yaml(f) }
      end

      def self.load_from_yaml(file)
        data = YAML.safe_load_file(file, permitted_classes: [Symbol])
        new(
          id: data["id"], title: data["title"],
          nqf_number: data["nqf_number"], scoring: data["scoring"]
        ).tap do |m|
          m.initial_population = data["initial_population"]
          m.denominator = data["denominator"]
          m.numerator = data["numerator"]
          m.denominator_exclusion = data["denominator_exclusion"]
        end
      end

      def persisted?
        id.present?
      end

      def self.resource_class
        "Measure"
      end

      def self.from_fhir_attributes(fhir_resource)
        resource = fhir_resource.is_a?(Hash) ? fhir_resource : fhir_resource.to_h
        scoring_hash = resource["scoring"] || resource[:scoring]
        coding_array = scoring_hash && (scoring_hash["coding"] || scoring_hash[:coding])
        scoring_code = coding_array&.first&.dig("code") || coding_array&.first&.dig(:code)
        {
          id: resource["id"] || resource[:id],
          title: resource["title"] || resource[:title],
          nqf_number: extract_nqf_from_fhir(resource),
          scoring: scoring_code || "proportion"
        }
      end

      def as_json(*)
        to_fhir
      end

      def to_fhir
        {
          resourceType: "Measure",
          id: id,
          title: title,
          status: "active",
          identifier: build_nqf_identifier,
          scoring: { coding: [{ code: scoring }] },
          group: build_groups
        }.compact
      end

      private

      def build_nqf_identifier
        return nil if nqf_number.blank?

        [{ system: "http://hl7.org/fhir/cqi/ecqm/Measure/Identifier/nqf", value: nqf_number }]
      end

      def build_groups
        [{
          population: build_populations
        }]
      end

      def build_populations
        populations = []
        populations << build_population_entry("initial-population", initial_population)
        populations << build_population_entry("denominator", denominator)
        populations << build_population_entry("numerator", numerator)
        if denominator_exclusion && denominator_exclusion[:description] != "None"
          populations << build_population_entry("denominator-exclusion", denominator_exclusion)
        end
        populations
      end

      def build_population_entry(code, _criteria)
        {
          code: { coding: [{ code: code }] }
        }
      end

      def self.extract_nqf_from_fhir(resource)
        identifiers = resource["identifier"] || resource[:identifier] || []
        nqf = identifiers.find { |i| (i["system"] || i[:system])&.include?("nqf") }
        nqf&.dig("value") || nqf&.dig(:value)
      end
    end
  end
end
