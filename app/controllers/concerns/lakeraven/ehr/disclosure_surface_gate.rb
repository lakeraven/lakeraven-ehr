# frozen_string_literal: true

module Lakeraven
  module EHR
    # Controller-level enforcement of the disclosure surfaces (#522;
    # docs/compliance/part2-disclosure-surface-audit.md §5(a)). The engine's
    # routing constraints refuse a closed surface on the engine's own routes;
    # this refuses it on ANY route that reaches the controller, including a
    # host route drawn straight at it.
    #
    # A controller names the surface its actions disclose through:
    #
    #   disclosure_surface :fhir_api
    #   disclosure_surface :fhir_api, only: :index
    #   disclosure_surface :fhir_api, if: :fhir_api_request?
    #
    # While that surface is closed (DisclosureSurfaces.open? — the predicate
    # the routing constraints use) the request answers a bodiless 404.
    #
    # ORDERING. The refusal wraps AbstractController::Base#process, which is
    # what calls process_action. Everything else a request runs lives inside
    # process_action: RateLimitable's RateLimitGate (prepended onto the class
    # that declares `rate_limit`, wherever that sits in the hierarchy), every
    # callback, prepended or not, the audit wrapper and the action itself.
    # So a closed surface answers before the rate limiter, before
    # authentication and before any broker call, whatever order `rate_limit`
    # and `disclosure_surface` are declared in, in a class or its ancestors.
    # (A module overriding `process` itself, included or prepended after this
    # one, would run first; none in this engine does.)
    #
    # Declarations are inherited and accumulate. A request is refused when
    # ANY declaration that governs its action names a closed surface.
    #
    # A declaration may carry a `key:`. A keyed declaration REPLACES an
    # inherited one with the same key instead of adding to it; that is how a
    # subclass restates which surface a shared rule names (SmartAuthentication's
    # header-token rule, `bearer_disclosure_surface`). Unkeyed declarations only
    # ever accumulate, so a subclass cannot drop one it inherited.
    module DisclosureSurfaceGate
      extend ActiveSupport::Concern

      # One declaration: the surface, the actions it governs (nil = every
      # action), an optional instance-method predicate and an optional key
      # (see above).
      Rule = Struct.new(:surface, :actions, :condition, :key) do
        def governs?(controller, action)
          return false if actions && !actions.include?(action)
          return true if condition.nil?

          controller.send(condition)
        end
      end

      included do
        class_attribute :disclosure_surface_rules, instance_accessor: false, default: [].freeze
      end

      class_methods do
        # `if:` is a Symbol naming a predicate method on the controller.
        # `key:` (a Symbol) replaces an inherited declaration with that key.
        def disclosure_surface(surface, only: nil, if: nil, key: nil)
          name = DisclosureSurfaces.known_name(surface)
          raise ArgumentError, "unknown disclosure surface: #{surface.inspect}" unless name

          condition = binding.local_variable_get(:if)
          unless condition.nil? || condition.is_a?(Symbol)
            raise ArgumentError, "disclosure_surface if: takes a method name (Symbol)"
          end

          raise ArgumentError, "disclosure_surface key: takes a Symbol" unless key.nil? || key.is_a?(Symbol)

          actions = only.nil? ? nil : Array(only).map(&:to_s).freeze
          rule = Rule.new(name, actions, condition, key).freeze
          inherited = key.nil? ? disclosure_surface_rules : disclosure_surface_rules.reject { |r| r.key == key }
          self.disclosure_surface_rules = (inherited + [ rule ]).freeze
        end
      end

      def process(action, ...)
        surface = closed_disclosure_surface(action.to_s)
        return super unless surface

        refuse_closed_disclosure_surface(surface)
      end

      private

      # The first governing declaration whose surface is closed, else nil.
      def closed_disclosure_surface(action)
        self.class.disclosure_surface_rules.each do |rule|
          next unless rule.governs?(self, action)
          return rule.surface unless DisclosureSurfaces.open?(rule.surface)
        end
        nil
      end

      # The same answer the routing constraint gives: a 404 with no body, so
      # nothing confirms a surface worth authenticating against.
      def refuse_closed_disclosure_surface(surface)
        Rails.logger.info("[disclosure_surface] #{surface} closed: #{controller_path} refused with 404")
        head :not_found
      end
    end
  end
end
