# frozen_string_literal: true

module Lakeraven
  module EHR
    # "None recorded" is a clinical finding. It is allowed only when ORQQAL
    # assessed NKA, nothing was dropped, the merged list is empty, and
    # the egress filter passed that empty list through whole. A raise, a
    # missing scope, a nil filter, a filter that dropped entries, an
    # unassessed patient, or an indeterminate reply is "not loaded".
    #
    # Not-loaded does not hide a name that did load. A dropped row or a
    # filter that withheld entries keeps the state not-loaded — never
    # "none recorded" — and the banner, the chart strip, the detail, and
    # the count all read this object. Names are only those the egress
    # filter returned; a nil payload is not a list, so nothing from the
    # unfiltered source is shown.
    class AllergyListStatus
      LOADED = "loaded"
      NONE_RECORDED = "none-recorded"
      NOT_LOADED = "not-loaded"
      UNNAMED_ALLERGY = "Unnamed allergy"
      INCOMPLETE_LIST = "list incomplete, other entries not loaded"

      attr_reader :state, :names

      def self.not_loaded(names = [])
        new(state: NOT_LOADED, names: names)
      end

      def self.from_counts(source_status:, source_count:, filtered_names:,
                           verified_absence: false, dropped_count: 0)
        if complete_reading?(source_status, source_count, filtered_names, dropped_count)
          return recorded(source_count, filtered_names) if verified_absence || source_count.positive?

          return not_loaded
        end

        not_loaded(passed_names(filtered_names))
      end

      # Text, then a coding display, then the code itself. A code with none
      # of those is still a real allergy and must not render as an empty span.
      def self.visible_allergen_name(code)
        return UNNAMED_ALLERGY unless code.is_a?(Hash)

        label = code_label(code, :text) || coding_label(code, :display) || coding_label(code, :code)
        label || UNNAMED_ALLERGY
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
        return "#{names.join(", ")} — #{INCOMPLETE_LIST}" if names.any?

        "Not loaded"
      end

      # A dash is an unknown total. Known names still count: the badge
      # would otherwise read as empty beside a list that has entries.
      def count_label
        return "0" if none_recorded?
        return "—" if names.empty?

        names.length.to_s
      end

      class << self
        private

        def recorded(source_count, filtered_names)
          if source_count.zero?
            new(state: NONE_RECORDED, names: [])
          else
            new(state: LOADED, names: filtered_names)
          end
        end

        # Nil is "the filter did not yield a countable list", not an
        # empty one. Only an Array is names that passed egress.
        def passed_names(filtered_names)
          filtered_names.is_a?(Array) ? filtered_names : []
        end

        def complete_reading?(source_status, source_count, filtered_names, dropped_count)
          dropped_count.to_i.zero? && complete_list?(source_status, source_count, filtered_names)
        end

        def complete_list?(source_status, source_count, filtered_names)
          source_status == :ok && filtered_names && filtered_names.length == source_count
        end

        def code_label(code, key)
          value = code[key]
          value = code[key.to_s] if value.nil?
          value.to_s.strip.presence
        end

        def coding_label(code, key)
          coding = code[:coding] || code["coding"]
          first = coding.is_a?(Array) ? coding.first : coding
          return unless first.is_a?(Hash)

          code_label(first, key)
        end

        def bundle_entries(payload)
          return nil unless payload.is_a?(Hash)

          entries = payload[:entry] || payload["entry"] || []
          entries if entries.is_a?(Array)
        end

        def allergy_name(entry)
          resource = entry_resource(entry)
          return nil unless allergy_resource?(resource)

          visible_allergen_name(resource[:code] || resource["code"])
        end

        def entry_resource(entry)
          return unless entry.is_a?(Hash)

          entry[:resource] || entry["resource"]
        end

        def allergy_resource?(resource)
          return false unless resource.is_a?(Hash)

          (resource[:resourceType] || resource["resourceType"]) == "AllergyIntolerance"
        end
      end
    end
  end
end
