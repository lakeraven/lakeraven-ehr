# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # FHIR ValueSet JSON on disk.
      #
      # The engine db/valuesets directory is searched first, then each
      # directory on TerminologyService.additional_valueset_paths. The
      # first file named for the ValueSet id wins. The id has to pass
      # ValueSetId: one file name, not a path, not "." or "..", and not a
      # hidden name. The resolved file has to stay inside that directory.
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
          valueset_paths.flat_map { |path| valuesets_in(path) }.uniq { |valueset| valueset["id"] || valueset["name"] }
        end

        def search(query)
          needle = query.downcase
          list_valuesets.select { |valueset| matches_query?(valueset, needle) }
        end

        def lookup_code(system, code)
          return nil if system.blank? || code.blank?

          list_valuesets.each do |valueset|
            match = codes_from(valueset).find { |entry| same_code?(entry, system, code) }
            return match if match
          end
          nil
        end

        def validate_code(system, code, valueset_id:)
          return false if system.blank? || code.blank?

          expand_valueset(valueset_id).any? { |entry| same_code?(entry, system, code) }
        end

        private

        def matches_query?(valueset, needle)
          valueset["title"]&.downcase&.include?(needle) || valueset["name"]&.downcase&.include?(needle)
        end

        def load_valueset(valueset_id)
          reject_unsafe_id!(valueset_id)

          valueset_paths.each do |directory|
            filepath = ValueSetId.file_for(directory, valueset_id)
            return JSON.parse(File.read(filepath)) if filepath
          end
          nil
        end

        def reject_unsafe_id!(valueset_id)
          return if ValueSetId.safe?(valueset_id)

          raise TerminologyService::ValueSetNotFoundError, "Local ValueSet not found: #{valueset_id}"
        end

        def valuesets_in(directory)
          Dir.glob(directory.join("*.json")).filter_map { |file| valueset_from(directory, file) }
        end

        def valueset_from(directory, file)
          readable = ValueSetId.contained_file(directory, file)
          JSON.parse(File.read(readable)) if readable
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

        # A blank system or code never matches. A concept with no code, or an
        # include with no system, is not a candidate.
        def same_code?(entry, system, code)
          return false if system.blank? || code.blank?
          return false if entry[:system].blank? || entry[:code].blank?

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
