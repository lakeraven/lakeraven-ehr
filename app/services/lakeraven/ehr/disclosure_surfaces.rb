# frozen_string_literal: true

module Lakeraven
  module EHR
    # The host-configured switch for the egress paths a 42 CFR Part 2 posture
    # may not need (#522; docs/compliance/part2-disclosure-surface-audit.md
    # §1 paths 2-4, §5(a)).
    #
    # A host opens a surface by naming it:
    #
    #   config.x.lakeraven_ehr.open_disclosure_surfaces = %i[fhir_api bulk_export ccda]
    #
    # FAIL CLOSED. Only an Array opens anything, and only its String or Symbol
    # entries that name one of NAMES. An absent key, nil, true, a bare String
    # or Symbol, a Hash, or an unknown name opens nothing. The value is read on
    # every call, so a change takes effect on the next request.
    module DisclosureSurfaces
      # fhir_api    — the FHIR REST resource routes, the chart's FHIR JSON and
      #               any header-authenticated chart read.
      # bulk_export — bulk EHI export ($export kick-off, status, files).
      # ccda        — C-CDA transitions of care (outbound documents).
      NAMES = %i[fhir_api bulk_export ccda].freeze

      module_function

      def open?(name)
        surface = known_name(name)
        return false unless surface

        configured = configured_surfaces
        return false unless configured.is_a?(Array)

        configured.any? { |entry| known_name(entry) == surface }
      end

      # The NAMES entry a String or Symbol spells, else nil.
      def known_name(value)
        return nil unless value.is_a?(String) || value.is_a?(Symbol)

        NAMES.find { |surface| surface.to_s == value.to_s }
      end

      def configured_surfaces
        options = Rails.application.config.x.lakeraven_ehr
        return nil unless options.is_a?(Hash)

        options[:open_disclosure_surfaces]
      end

      # A routing constraint: the governed routes only match while their
      # surface is open, so a closed surface is a plain 404 and no controller
      # code (authentication, broker calls) runs. Defence in depth: each
      # governed controller also refuses a closed surface itself
      # (DisclosureSurfaceGate), which is what covers a host route drawn
      # straight at the controller.
      class RouteConstraint
        def initialize(surface)
          raise ArgumentError, "unknown disclosure surface: #{surface.inspect}" unless DisclosureSurfaces.known_name(surface)

          @surface = surface
          freeze
        end

        def matches?(_request)
          DisclosureSurfaces.open?(@surface)
        end
      end

      # The chart route serves the HTML chart to a browser session (never
      # governed) and, to fhir_api, its FHIR Bundle and any request carrying
      # an Authorization header. It matches unless the request is one of
      # those while fhir_api is closed, by the same rule
      # (ChartRepresentation.fhir_api_request?) ChartsController's disclosure
      # gate applies.
      class ChartRouteConstraint
        def matches?(request)
          return true unless ChartRepresentation.fhir_api_request?(request)

          DisclosureSurfaces.open?(:fhir_api)
        end
      end
    end
  end
end
