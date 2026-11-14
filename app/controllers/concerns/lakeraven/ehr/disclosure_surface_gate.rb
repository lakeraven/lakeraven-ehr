# frozen_string_literal: true

module Lakeraven
  module EHR
    # Keeps a disclosure surface (#968) closed until the host opens it by name
    # (DisclosureSurfaces). A controller declares the surface it serves:
    #
    #   disclosure_surface :bulk_export
    #
    # A closed surface answers a bare 404 from #process, which wraps
    # process_action: ahead of the rate limit gate, every callback, auth,
    # audit and the action, so a closed route does no work and says nothing.
    module DisclosureSurfaceGate
      extend ActiveSupport::Concern

      included do
        class_attribute :disclosure_surface_rules, instance_accessor: false, default: [].freeze
      end

      class_methods do
        def disclosure_surface(surface, only: nil)
          name = DisclosureSurfaces.known_name(surface)
          raise ArgumentError, "unknown disclosure surface: #{surface.inspect}" unless name

          actions = only && Array(only).map(&:to_s).freeze
          rule = { surface: name, only: actions }.freeze
          self.disclosure_surface_rules = (disclosure_surface_rules + [ rule ]).freeze
        end
      end

      def process(action, ...)
        closed = closed_disclosure_surface(action.to_s)
        return super unless closed

        Rails.logger.info("[disclosure_surface] #{closed} closed: #{controller_path} refused with 404")
        head :not_found
      end

      private

      def closed_disclosure_surface(action)
        self.class.disclosure_surface_rules.each do |rule|
          next if rule[:only] && !rule[:only].include?(action)
          return rule[:surface] unless DisclosureSurfaces.open?(rule[:surface])
        end
        nil
      end
    end
  end
end
