# frozen_string_literal: true

module Lakeraven
  module EHR
    module Terminology
      # In-memory ValueSets. Keys are ids. Each value has "title", "name",
      # and "codes" entries of system, code, and display.
      class MockAdapter < BaseAdapter
        def initialize(valuesets: {})
          @valuesets = valuesets
        end

        def backend
          :mock
        end

        def expand_valueset(valueset_id)
          valueset = fetch(valueset_id)
          raise TerminologyService::ValueSetNotFoundError, "ValueSet not found: #{valueset_id}" unless valueset

          codes_from(valueset)
        end

        def get_valueset(valueset_id)
          valueset = fetch(valueset_id)
          return nil unless valueset

          metadata(valueset_id, valueset)
        end

        def list_valuesets
          @valuesets.map { |id, valueset| metadata(id, valueset) }
        end

        def search(query)
          needle = query.to_s.downcase
          list_valuesets.select { |valueset| matches_query?(valueset, needle) }
        end

        def lookup_code(system, code)
          return nil if system.blank? || code.blank?

          @valuesets.each_value do |valueset|
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

        def fetch(valueset_id)
          @valuesets[valueset_id] || @valuesets[valueset_id.to_s]
        end

        def metadata(id, valueset)
          {
            "resourceType" => "ValueSet",
            "id" => id.to_s,
            "name" => valueset["name"],
            "title" => valueset["title"],
            "status" => valueset["status"] || "active"
          }
        end

        def matches_query?(valueset, needle)
          valueset["title"]&.downcase&.include?(needle) || valueset["name"]&.downcase&.include?(needle)
        end

        def codes_from(valueset)
          Array(valueset["codes"] || valueset[:codes]).map { |entry| code_entry(entry) }
        end

        def code_entry(entry)
          {
            system: entry[:system] || entry["system"],
            code: entry[:code] || entry["code"],
            display: entry[:display] || entry["display"]
          }
        end

        # A blank system or code never matches. A code entry with no system
        # or no code is not a candidate.
        def same_code?(entry, system, code)
          return false if system.blank? || code.blank?
          return false if entry[:system].blank? || entry[:code].blank?

          entry[:system] == system && entry[:code] == code
        end
      end
    end
  end
end
