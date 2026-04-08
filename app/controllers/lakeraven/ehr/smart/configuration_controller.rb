# frozen_string_literal: true

module Lakeraven
  module EHR
    module Smart
      # SMART App Launch discovery document, served at:
      #
      #   GET /.well-known/smart-configuration
      #
      # Reference: http://hl7.org/fhir/smart-app-launch/conformance.html
      #
      # The discovery doc is unauthenticated by design — clients hit it
      # before they have a token to find out where the OAuth endpoints
      # live.
      class ConfigurationController < ::ActionController::API
        def show
          render json: smart_configuration, content_type: "application/json"
        end

        private

        def smart_configuration
          {
            authorization_endpoint: oauth_authorization_url,
            token_endpoint: oauth_token_url,
            revocation_endpoint: oauth_revoke_url,

            capabilities: capabilities,
            scopes_supported: scopes_supported,

            grant_types_supported: %w[authorization_code client_credentials refresh_token],
            response_types_supported: %w[code],
            code_challenge_methods_supported: %w[S256],

            token_endpoint_auth_methods_supported: %w[
              client_secret_basic
              client_secret_post
            ]
          }
        end

        # SMART App Launch capabilities advertised by this server.
        # See http://hl7.org/fhir/smart-app-launch/conformance.html#capabilities
        def capabilities
          # client-public is intentionally NOT advertised: the
          # Doorkeeper schema requires oauth_applications.secret to
          # be non-null, so public clients (which have no secret)
          # can't actually be registered. Adding public-client
          # support is a follow-up that needs a schema change and
          # PKCE-only client validation.
          %w[
            launch-ehr
            launch-standalone
            client-confidential-symmetric
            context-passthrough-banner
            context-passthrough-style
            context-ehr-patient
            context-ehr-encounter
            context-standalone-patient
            context-standalone-encounter
            permission-offline
            permission-patient
            permission-user
            permission-v2
          ]
        end

        # Mirrors the optional_scopes registered with Doorkeeper in
        # config/initializers/doorkeeper.rb. Both lists must move
        # together — clients use this list to know what they can
        # request, Doorkeeper uses its list to validate.
        def scopes_supported
          [
            "openid",
            "profile",
            "fhirUser",
            "launch",
            "launch/patient",
            "launch/practitioner",
            "offline_access",
            "patient/Patient.read",
            "patient/Practitioner.read",
            "patient/Observation.read",
            "patient/Condition.read",
            "patient/Encounter.read",
            "patient/AllergyIntolerance.read",
            "patient/Immunization.read",
            "patient/Medication.read",
            "patient/MedicationRequest.read",
            "user/Patient.read",
            "user/Practitioner.read",
            "user/Patient.write",
            "system/Patient.read",
            "system/Practitioner.read",
            "system/*.read"
          ]
        end

        # OAuth endpoint URL helpers — these are mounted by Doorkeeper
        # under the engine, so use the engine's URL helpers to
        # construct absolute URLs.
        def oauth_authorization_url
          Lakeraven::EHR::Engine.routes.url_helpers.oauth_authorization_url(host: request.host_with_port, protocol: request.protocol)
        end

        def oauth_token_url
          Lakeraven::EHR::Engine.routes.url_helpers.oauth_token_url(host: request.host_with_port, protocol: request.protocol)
        end

        def oauth_revoke_url
          Lakeraven::EHR::Engine.routes.url_helpers.oauth_revoke_url(host: request.host_with_port, protocol: request.protocol)
        end
      end
    end
  end
end
