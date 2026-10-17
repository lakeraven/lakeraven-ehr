# frozen_string_literal: true

module Lakeraven
  module EHR
    # "None recorded" is a clinical finding. It is allowed only when the
    # source returned a complete list and the egress filter passed every
    # entry through. A raise, a missing scope, a nil filter, or a filter
    # that dropped entries is "not loaded" — a missing list is not a negative.
    class AllergyListStatus
      LOADED = "loaded"
      NONE_RECORDED = "none-recorded"
      NOT_LOADED = "not-loaded"

      attr_reader :state, :names

      def self.not_loaded
        new(state: NOT_LOADED, names: [])
      end

      def self.from_counts(source_status:, source_count:, filtered_names:)
        return not_loaded unless complete_list?(source_status, source_count, filtered_names)

        if source_count.zero?
          new(state: NONE_RECORDED, names: [])
        else
          new(state: LOADED, names: filtered_names)
        end
      end

      # Names of AllergyIntolerance entries in a filtered bundle, or nil when
      # the payload is not a bundle we can count. Nil is "not loaded": we
      # cannot prove the list was passed through whole.
      def self.names_in(payload)
        entries = bundle_entries(payload)
        return nil unless entries

        entries.filter_map { |entry| allergy_name(entry) }
      end

      def initialize(state:, names:)
        @state = state
        @names = names
      end

      def loaded?
        state == LOADED
      end

      def none_recorded?
        state == NONE_RECORDED
      end

      def text
        return names.join(", ") if loaded?
        return "None recorded" if none_recorded?

        "Not loaded"
      end

      def count_label
        return names.length.to_s if loaded?
        return "0" if none_recorded?

        "—"
      end

      class << self
        private

        def complete_list?(source_status, source_count, filtered_names)
          source_status == :ok && filtered_names && filtered_names.length == source_count
        end

        def bundle_entries(payload)
          return nil unless payload.is_a?(Hash)

          entries = payload[:entry] || payload["entry"] || []
          entries if entries.is_a?(Array)
        end

        def allergy_name(entry)
          resource = entry_resource(entry)
          return nil unless allergy_resource?(resource)

          code_text(resource).to_s
        end

        def entry_resource(entry)
          return unless entry.is_a?(Hash)

          entry[:resource] || entry["resource"]
        end

        def allergy_resource?(resource)
          return false unless resource.is_a?(Hash)

          (resource[:resourceType] || resource["resourceType"]) == "AllergyIntolerance"
        end

        def code_text(resource)
          code = resource[:code] || resource["code"]
          return if code.nil?

          code[:text] || code["text"] || coding_display(code)
        end

        def coding_display(code)
          coding = code[:coding] || code["coding"]
          first = coding.is_a?(Array) ? coding.first : coding
          return unless first.is_a?(Hash)

          first[:display] || first["display"]
        end
      end
    end
  end
end
