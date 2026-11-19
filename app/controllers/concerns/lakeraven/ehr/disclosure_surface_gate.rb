# frozen_string_literal: true

module Lakeraven
  module EHR
    # Keeps a disclosure surface (#968) closed until the host opens it by name
    # (DisclosureSurfaces). A controller declares the surface it serves:
    #
    #   disclosure_surface :bulk_export
    #   disclosure_surface :fhir_api, if: :bearer_request?, key: :bearer
    #
    # +if:+ names a predicate method: the rule applies only when it is true,
    # and a predicate that raises applies the rule (fail closed). A later
    # declaration with the same +key:+ replaces the earlier rule, so a
    # subclass can restate an inherited one.
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
        def disclosure_surface(surface, only: nil, if: nil, key: nil)
          name = DisclosureSurfaces.known_name(surface)
          raise ArgumentError, "unknown disclosure surface: #{surface.inspect}" unless name

          actions = only && Array(only).map(&:to_s).freeze
          condition = binding.local_variable_get(:if)
          rule = { surface: name, only: actions }
          rule[:if] = condition.to_sym if condition
          rule[:key] = key if key
          rules = disclosure_surface_rules.dup
          index = key && rules.index { |existing| existing[:key] == key }
          rules[index || rules.size] = rule.freeze
          self.disclosure_surface_rules = rules.freeze
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
          next unless disclosure_rule_applies?(rule)
          return rule[:surface] unless DisclosureSurfaces.open?(rule[:surface])
        end
        nil
      end

      # A predicate that raises cannot show the rule is moot, so the rule
      # applies: an error closes the surface rather than opening it.
      def disclosure_rule_applies?(rule)
        return true unless rule[:if]

        send(rule[:if]) ? true : false
      rescue StandardError
        true
      end
    end
  end
end
