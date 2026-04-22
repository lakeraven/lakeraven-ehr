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
        data = YAML.load_file(file)
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

      def to_fhir
        { resourceType: "Measure", id: id, title: title, scoring: { coding: [ { code: scoring } ] } }
      end
    end
  end
end
