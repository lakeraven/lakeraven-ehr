# frozen_string_literal: true

module Lakeraven
  module EHR
    # What the engine tells a SMART client about its authorization server,
    # built in one place so .well-known/smart-configuration and the
    # CapabilityStatement's security element cannot disagree (#657).
    #
    # Only what is served (#657). The engine serves:
    #   - SMART Backend Services: client_credentials, the client authenticated
    #     by an RS384-signed JWT (BackendServicesController);
    #   - SMART App Launch (#839): the authorization endpoint (GET and POST),
    #     standalone and EHR launch, PKCE S256, public, client-secret and
    #     private_key_jwt clients (RS384 or ES384), patient and user scopes,
    #     the patient picker, need_patient_banner and smart_style_url
    #     (SmartAuthorizationsController, SmartTokensController).
    # Not claimed, because not served: OpenID Connect and fhirUser (#841),
    # refresh tokens and offline_access (#840), introspection and revocation
    # endpoints (#842), and context-ehr-encounter, because the Encounter a
    # launch names cannot be read yet (#845). context-standalone-encounter is
    # not offered at all.
    #
    # scopes_supported (below) is the Backend Services set: it is optional,
    # and the launch scopes a user gets depend on their own RPMS access
    # (LaunchScopePolicy), so no fixed list would be true for everyone.
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
      GRANT_TYPES = %w[authorization_code client_credentials].freeze
      AUTH_METHODS = %w[client_secret_basic client_secret_post private_key_jwt].freeze
      SIGNING_ALGORITHMS = (BackendServicesController::ALLOWED_ALGORITHMS | LaunchClient::ASSERTION_ALGORITHMS).freeze
      # permission-v1: a v1 scope in a request or a client registration is
      # accepted and translated to v2 (SmartScope). Tokens carry v2.
      CAPABILITIES = %w[
        launch-standalone launch-ehr authorize-post
        client-public client-confidential-symmetric client-confidential-asymmetric
        context-standalone-patient context-ehr-patient context-banner context-style
        permission-patient permission-user permission-v1 permission-v2
      ].freeze
      READ_WILDCARD = "system/*.rs"
      INTERACTION_PERMISSIONS = { "create" => "c", "read" => "r", "search-type" => "s" }.freeze

      def initialize(token_endpoint:)
        @token_endpoint = token_endpoint
      end

      # Beside the token endpoint, as SmartEndpoints builds both.
      def authorization_endpoint
        @token_endpoint.sub(%r{/oauth/token\z}, "/oauth/authorize")
      end

      # The body of .well-known/smart-configuration.
      def configuration
        {
          authorization_endpoint: authorization_endpoint,
          token_endpoint: @token_endpoint,
          token_endpoint_auth_methods_supported: AUTH_METHODS,
          token_endpoint_auth_signing_alg_values_supported: SIGNING_ALGORITHMS,
          grant_types_supported: GRANT_TYPES,
          response_types_supported: %w[code],
          scopes_supported: scopes_supported,
          # S256 only: every client must use it, and plain is refused.
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
            extension: [
              { url: "authorize", valueUri: authorization_endpoint },
              { url: "token", valueUri: @token_endpoint }
            ]
          } ],
          service: [ {
            coding: [ {
              system: "http://terminology.hl7.org/CodeSystem/restful-security-service",
              code: "SMART-on-FHIR"
            } ]
          } ],
          description: "SMART App Launch (authorization code with PKCE) and SMART Backend Services " \
                       "(client_credentials). .well-known/smart-configuration lists the endpoints, scopes and capabilities."
        }
      end
    end
  end
end
