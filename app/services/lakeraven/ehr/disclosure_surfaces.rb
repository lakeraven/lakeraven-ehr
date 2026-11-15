# frozen_string_literal: true

module Lakeraven
  module EHR
    # The named disclosure surfaces (#968, after the #522 Part 2 audit). Every
    # surface is CLOSED until the host opens it by name:
    #
    #   config.x.lakeraven_ehr.open_disclosure_surfaces = %i[bulk_export]
    #
    # Fail closed: only an Array opens anything, and only its String/Symbol
    # entries that spell a name exactly. Anything else -- a bare name, true, a
    # Hash, an unreadable options object -- opens nothing.
    module DisclosureSurfaces
      module_function

      NAMES = %i[fhir_api bulk_export ccda].freeze
      KEY = :open_disclosure_surfaces

      def open?(name)
        surface = known_name(name)
        return false unless surface

        configured_surfaces.include?(surface)
      end

      # The Symbol in NAMES that +value+ spells exactly, else nil.
      def known_name(value)
        return unless value.is_a?(String) || value.is_a?(Symbol)

        NAMES.find { |name| name.to_s == value.to_s }
      end

      # The known names the host opened. Read fresh on every call.
      def configured_surfaces
        options = Rails.application.config.x.lakeraven_ehr
        return [] unless options.is_a?(Hash)

        value = options.key?(KEY) ? options[KEY] : options[KEY.to_s]
        return [] unless value.is_a?(Array)

        value.filter_map { |entry| known_name(entry) }.uniq
      end
    end
  end
end
