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

      # API routes not yet behind any surface, each with why. C-CDA is the
      # :ccda surface's own slice (#969); until then a bearer request to
      # these is still fhir_api (SmartAuthentication's bearer rule).
      UNGOVERNED_API_ROUTES = {
        "lakeraven/ehr/ccda_imports#create" => "C-CDA import: gated as :ccda in #969; bearer requests are fhir_api until then",
        "lakeraven/ehr/transitions_of_care#create" => "C-CDA generation: gated as :ccda in #969; bearer requests are fhir_api until then"
      }.freeze

      # "controller#action" for every FHIR API route of +route_set+ that no
      # unconditional disclosure_surface rule covers, less +allow+. An API
      # route is one to an ApplicationController descendant, or one whose
      # path starts with an uppercase letter or "$" (FHIR's shape). A
      # FHIR-shaped route whose controller cannot be loaded is reported.
      def ungated_routes(route_set, allow: UNGOVERNED_API_ROUTES.keys)
        route_set.routes.filter_map do |route|
          name = route.defaults[:controller] ? "#{route.defaults[:controller]}##{route.defaults[:action]}" : route.path.spec.to_s
          klass = route_controller(route.defaults[:controller])
          api = (klass && klass < ApplicationController) || fhir_path?(route.path.spec.to_s)
          next unless api && allow.exclude?(name)

          name unless gated?(klass, route.defaults[:action].to_s)
        end.uniq
      end

      def fhir_path?(spec)
        spec.delete_prefix("/").match?(/\A[A-Z$]/)
      end

      def route_controller(controller)
        return if controller.blank?

        "#{controller}_controller".camelize.safe_constantize
      rescue StandardError, LoadError
        nil
      end

      def gated?(klass, action)
        return false unless klass.respond_to?(:disclosure_surface_rules)

        klass.disclosure_surface_rules.any? do |rule|
          (rule[:only].nil? || rule[:only].include?(action)) && rule.except(:surface, :only).values.none?
        end
      end

      # Draws routes only while +surface+ is open, read fresh per request.
      class RouteConstraint
        attr_reader :surface

        def initialize(surface)
          @surface = DisclosureSurfaces.known_name(surface)
          raise ArgumentError, "unknown disclosure surface: #{surface.inspect}" unless @surface
        end

        def matches?(_request)
          DisclosureSurfaces.open?(surface)
        end
      end
    end
  end
end
