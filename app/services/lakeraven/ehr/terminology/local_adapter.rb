# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # FHIR ValueSet JSON on disk.
      #
      # The engine db/valuesets directory is searched first, then each
      # directory on TerminologyService.additional_valueset_paths. The
      # first file named for the ValueSet id wins.
      class LocalAdapter < BaseAdapter
        def backend
          :local
        end

        def expand_valueset(valueset_id)
          valueset = load_valueset(valueset_id)
          raise TerminologyService::ValueSetNotFoundError, "Local ValueSet not found: #{valueset_id}" unless valueset

          codes_from(valueset)
        end

        def get_valueset(valueset_id)
          load_valueset(valueset_id)
        end

        def list_valuesets
          valueset_paths.flat_map do |path|
            Dir.glob(path.join("*.json")).map { |file| JSON.parse(File.read(file)) }
          end.uniq { |valueset| valueset["id"] || valueset["name"] }
        end

        def search(query)
          needle = query.downcase
          list_valuesets.select { |valueset| matches_query?(valueset, needle) }
        end

        def lookup_code(system, code)
          list_valuesets.each do |valueset|
            match = codes_from(valueset).find { |entry| same_code?(entry, system, code) }
            return match if match
          end
          nil
        end

        def validate_code(system, code, valueset_id:)
          expand_valueset(valueset_id).any? { |entry| same_code?(entry, system, code) }
        end

        private

        def matches_query?(valueset, needle)
          valueset["title"]&.downcase&.include?(needle) || valueset["name"]&.downcase&.include?(needle)
        end

        def load_valueset(valueset_id)
          filename = "#{valueset_id}.json"
          valueset_paths.each do |path|
            filepath = path.join(filename)
            return JSON.parse(File.read(filepath)) if File.exist?(filepath)
          end
          nil
        end

        def codes_from(valueset)
          includes = valueset.dig("compose", "include") || []
          includes.flat_map { |include_set| concepts_from(include_set) }
        end

        def concepts_from(include_set)
          system = include_set["system"]
          concepts = include_set["concept"] || []
          concepts.map { |concept| concept_entry(system, concept) }
        end

        def concept_entry(system, concept)
          { system: system, code: concept["code"], display: concept["display"] }
        end

        def same_code?(entry, system, code)
          entry[:system] == system && entry[:code] == code
        end

        def valueset_paths
          paths = [ Lakeraven::EHR::Engine.root.join("db", "valuesets") ]
          paths.concat(TerminologyService.additional_valueset_paths.map { |path| Pathname.new(path) })
          paths.select { |path| path.exist? }
        end
      end
    end
  end
end
