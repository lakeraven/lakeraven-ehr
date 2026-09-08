# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART App Launch Framework - Well-Known Configuration
    # ONC 170.315(g)(10) — SMART on FHIR discovery endpoint
    class SmartConfigurationController < ActionController::API
      def show
        render json: smart_configuration, status: :ok
      end

      private

      def smart_configuration
        {
          authorization_endpoint: "#{base_url}oauth/authorize",
          token_endpoint: token_endpoint,
          userinfo_endpoint: "#{base_url}oauth/userinfo",
          jwks_uri: "#{base_url}.well-known/jwks.json",
          scopes_supported: supported_scopes,
          response_types_supported: [ "code" ],
          grant_types_supported: %w[authorization_code client_credentials refresh_token],
          token_endpoint_auth_methods_supported: [ "private_key_jwt" ],
          token_endpoint_auth_signing_alg_values_supported: %w[RS384 RS256 ES384],
          code_challenge_methods_supported: [ "S256" ],
          capabilities: capabilities
        }
      end

      def base_url
        request.base_url + "/"
      end

      # Must match the audience BackendServicesController verifies client
      # assertions against — the configured published URL when set, else the
      # request-derived fallback (dev/test).
      def token_endpoint
        Lakeraven::EHR.configuration.token_endpoint_url.presence ||
          "#{base_url}oauth/token"
      end

      def supported_scopes
        %w[
          openid fhirUser
          launch launch/patient
          patient/Patient.read patient/AllergyIntolerance.read
          patient/Condition.read patient/MedicationRequest.read
          patient/Observation.read patient/Immunization.read
          patient/Procedure.read patient/Encounter.read
          user/Patient.read user/AllergyIntolerance.read
          user/Condition.read user/MedicationRequest.read
          user/Observation.read
          system/Patient.read system/Condition.read
          system/MedicationRequest.read system/Medication.read
          system/Observation.read system/DiagnosticReport.read
          system/CarePlan.read system/AllergyIntolerance.read
          system/Encounter.read system/Practitioner.read
          system/Provenance.read
          system/*.read system/*.write system/*.*
        ]
      end

      def capabilities
        %w[
          launch-ehr launch-standalone
          client-public client-confidential-symmetric client-confidential-asymmetric
          sso-openid-connect
          context-ehr-patient context-ehr-encounter
          context-standalone-patient
          permission-offline permission-patient permission-user
        ]
      end
    end
  end
end
