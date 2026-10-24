# frozen_string_literal: true

module Lakeraven
  module EHR
    # One SMART clinical scope, held in the SMART App Launch v2 grammar:
    # `<context>/<Type|*>.<permissions>`, where the permissions are a subset
    # of c, r, u, d, s written in that order.
    #
    # The engine mints v2 and checks v2. A v1 scope (`.read`, `.write`, `.*`)
    # is still accepted, from a request, a token or a client registration,
    # and is translated here, at the edge, so no other code reads v1:
    #
    #   .read  -> .rs     read by id and search
    #   .write -> .cud    create, update, delete
    #   .*     -> .cruds  everything
    #
    # A scope this class cannot read grants nothing. That includes v2 granular
    # scopes (`patient/Observation.rs?category=...`): the engine cannot apply
    # the query, so honouring the scope would grant more than it asks for.
    class SmartScope
      PERMISSIONS = %w[c r u d s].freeze
      CONTEXTS = %w[patient user system].freeze
      V1_PERMISSIONS = { "read" => "rs", "write" => "cud", "*" => "cruds" }.freeze
      GRAMMAR = %r{\A(patient|user|system)/([A-Z][A-Za-z]*|\*)\.([a-z]+|\*)\z}

      attr_reader :context, :resource_type, :permissions

      class << self
        # The scope, or nil for anything that is not a clinical scope
        # (openid, launch, a granular scope, a malformed one).
        def parse(string)
          match = GRAMMAR.match(string.to_s)
          return nil unless match

          letters = V1_PERMISSIONS.fetch(match[3], match[3])
          return nil unless ordered_permissions?(letters)

          new(match[1], match[2], letters.chars)
        end

        def parse_all(scopes)
          scope_list(scopes).filter_map { |scope| parse(scope) }
        end

        # Does any scope in `scopes` (a space-separated string or an array)
        # grant `permission` (one of c r u d s) on `resource_type`?
        def permits?(scopes, resource_type, permission, contexts: CONTEXTS)
          parse_all(scopes).any? do |scope|
            contexts.include?(scope.context) && scope.permits?(resource_type, permission)
          end
        end

        # The v2 spelling of a scope; a non-clinical scope comes back as it
        # was given.
        def normalize(string)
          parse(string)&.to_s || string.to_s
        end

        def build(context, resource_type, permissions)
          new(context, resource_type, permissions.to_s.chars)
        end

        private

        def scope_list(scopes)
          scopes.is_a?(Array) ? scopes.map(&:to_s) : scopes.to_s.split
        end

        def ordered_permissions?(letters)
          letters.present? && PERMISSIONS.select { |p| letters.include?(p) }.join == letters
        end
      end

      def initialize(context, resource_type, permissions)
        @context = context
        @resource_type = resource_type
        @permissions = PERMISSIONS & permissions
      end

      def permits?(type, permission)
        covers_type?(type) && permissions.include?(permission)
      end

      # What `registered` lets a client holding it be granted of this
      # requested scope: the requested type, the permissions both name. A
      # registered wildcard covers a requested type; a registered type does
      # not cover a requested wildcard. Nil when nothing is left.
      def narrowed_by(registered)
        return nil unless registered.context == context && registered.covers_type?(resource_type)

        common = permissions & registered.permissions
        common.empty? ? nil : self.class.new(context, resource_type, common)
      end

      def merge(other)
        self.class.new(context, resource_type, permissions | other.permissions)
      end

      def covers_type?(type)
        resource_type == "*" || resource_type == type
      end

      def to_s
        "#{context}/#{resource_type}.#{permissions.join}"
      end
    end
  end
end
