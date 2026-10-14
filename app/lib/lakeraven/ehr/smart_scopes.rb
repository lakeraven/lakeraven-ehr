# frozen_string_literal: true

module Lakeraven
  module EHR
    # The one definition of what a SMART scope string permits.
    #
    # Two places ask about scopes: the FHIR API asks whether a token's scopes
    # permit an access (SmartAuthentication#scope_permits?), and the token
    # endpoint asks whether a client's registration covers a requested scope
    # (BackendServicesController#granted_scopes). They must agree about what a
    # wildcard covers, or the token endpoint refuses scopes the API would honour
    # (or, worse, grants scopes the registration never permitted). Both answer
    # from the table below.
    module SmartScopes
      extend self

      CONTEXTS = %w[patient user system].freeze

      # The scope actions that satisfy each kind of access. A write scope never
      # satisfies a read, and a read scope never satisfies a write.
      ACTIONS = {
        read: %w[read *],
        write: %w[write c *]
      }.freeze

      SCOPE_FORMAT = %r{\A(?<context>patient|user|system)/(?<type>[A-Za-z]+|\*)\.(?<action>[^.\s]+)\z}

      # Whether any of +scopes+ permits +access+ (:read or :write) on
      # +resource_type+ in one of +contexts+. A resource_type of "*" asks about
      # every resource type at once, which only a wildcard type permits.
      def permits?(scopes, resource_type, access, contexts: CONTEXTS)
        allowed = contexts.flat_map do |context|
          ACTIONS.fetch(access).flat_map do |action|
            [ "#{context}/#{resource_type}.#{action}", "#{context}/*.#{action}" ]
          end
        end
        (Array(scopes) & allowed).any?
      end

      # Whether +held+ (a list of scope strings) covers +requested+: every access
      # +requested+ permits, +held+ also permits, in the requested scope's own
      # context. An exact match always covers. A scope that permits nothing
      # (malformed, or an action outside ACTIONS) is covered only by an exact
      # match, so this never widens what +held+ allows.
      def covers?(held, requested)
        held = Array(held)
        return true if held.include?(requested)

        match = SCOPE_FORMAT.match(requested)
        return false unless match

        contexts = [ match[:context] ]
        type = match[:type]
        accesses = ACTIONS.keys.select { |access| permits?([ requested ], type, access, contexts: contexts) }
        return false if accesses.empty?

        accesses.all? { |access| permits?(held, type, access, contexts: contexts) }
      end
    end
  end
end
