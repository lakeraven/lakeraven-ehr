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
          token_endpoint: "#{base_url}oauth/token",
          userinfo_endpoint: "#{base_url}oauth/userinfo",
          jwks_uri: "#{base_url}.well-known/jwks.json",
          scopes_supported: supported_scopes,
          response_types_supported: [ "code" ],
          grant_types_supported: %w[authorization_code client_credentials refresh_token],
          code_challenge_methods_supported: [ "S256" ],
          capabilities: capabilities
        }
      end

      def base_url
        request.base_url + "/"
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
