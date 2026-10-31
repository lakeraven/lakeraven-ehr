# frozen_string_literal: true

module Lakeraven
  module EHR
    # What the engine tells a SMART client about its authorization server,
    # built in one place so .well-known/smart-configuration and the
    # CapabilityStatement's security element cannot disagree (#657).
    #
    # Only what is served. The engine serves SMART Backend Services: a
    # client_credentials grant at the token endpoint, the client
    # authenticated by an RS384-signed JWT (BackendServicesController). No
    # authorization endpoint is routed, so this claims no launch, no
    # authorization-code grant, no OpenID Connect, no userinfo or JWKS
    # endpoint, and no patient/ or user/ scope a client could obtain.
    #
    # scopes_supported lists only what the token endpoint grants and the API
    # honours (#658), in SMART v2 form: the read wildcard, and one scope per
    # type /metadata serves on the current backend, with the permissions
    # those served interactions need. The types and interactions come from
    # CapabilityStatement.served_interactions_by_type, the same map the
    # CapabilityStatement is built from, so the two documents cannot disagree.
    # No wildcard write, no `*.*`.
    class SmartDiscovery
      OAUTH_URIS = "http://fhir-registry.smarthealthit.org/StructureDefinition/oauth-uris"
      GRANT_TYPES = %w[client_credentials].freeze
      AUTH_METHODS = %w[private_key_jwt].freeze
      # permission-v1: a v1 scope in a request or a client registration is
      # accepted and translated to v2 (SmartScope). Tokens carry v2.
      CAPABILITIES = %w[client-confidential-asymmetric permission-v1 permission-v2].freeze
      READ_WILDCARD = "system/*.rs"
      INTERACTION_PERMISSIONS = { "create" => "c", "read" => "r", "search-type" => "s" }.freeze

      def initialize(token_endpoint:)
        @token_endpoint = token_endpoint
      end

      # The body of .well-known/smart-configuration.
      def configuration
        {
          token_endpoint: @token_endpoint,
          token_endpoint_auth_methods_supported: AUTH_METHODS,
          token_endpoint_auth_signing_alg_values_supported: BackendServicesController::ALLOWED_ALGORITHMS,
          grant_types_supported: GRANT_TYPES,
          scopes_supported: scopes_supported,
          # Required by SMART App Launch v2 even where no authorization code
          # is issued; S256 is the only method the spec permits.
          code_challenge_methods_supported: %w[S256],
          capabilities: CAPABILITIES
        }
      end

      def scopes_supported
        per_type = FHIR::CapabilityStatement.served_interactions_by_type.filter_map do |type, interactions|
          permissions = interactions.filter_map { |code| INTERACTION_PERMISSIONS[code] }.join
          SmartScope.build("system", type, permissions).to_s if permissions.present?
        end
        [ READ_WILDCARD, *per_type ]
      end

      # The CapabilityStatement's rest.security element. It names the
      # endpoints, never scopes: scopes are smart-configuration's to list.
      def security
        {
          extension: [ {
            url: OAUTH_URIS,
            extension: [ { url: "token", valueUri: @token_endpoint } ]
          } ],
          service: [ {
            coding: [ {
              system: "http://terminology.hl7.org/CodeSystem/restful-security-service",
              code: "SMART-on-FHIR"
            } ]
          } ],
          description: "SMART Backend Services (client_credentials). " \
                       ".well-known/smart-configuration lists the token endpoint, scopes and capabilities."
        }
      end
    end
  end
end
