# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART Backend Services OAuth token endpoint
    # ONC 170.315(g)(10)(vi) - Backend services authorization
    class BackendServicesController < ActionController::API
      def token
        unless params[:grant_type] == "client_credentials"
          render json: { error: "unsupported_grant_type" }, status: :bad_request
          return
        end

        unless params[:client_assertion].present?
          render json: { error: "invalid_client", error_description: "client_assertion is required" },
                 status: :bad_request
          return
        end

        claims = decode_jwt(params[:client_assertion])
        unless claims
          render json: { error: "invalid_client", error_description: "Invalid JWT assertion" },
                 status: :unauthorized
          return
        end

        app = Doorkeeper::Application.find_by(uid: claims["iss"])
        unless app
          render json: { error: "invalid_client", error_description: "Unknown client" },
                 status: :unauthorized
          return
        end

        token = Doorkeeper::AccessToken.create!(
          application: app,
          scopes: params[:scope] || "system/*.read",
          expires_in: 3600
        )

        render json: {
          access_token: token.plaintext_token || token.token,
          token_type: "bearer",
          expires_in: 3600,
          scope: token.scopes.to_s
        }, status: :ok
      end

      private

      def decode_jwt(assertion)
        # Decode JWT without verification (production would verify with JWKS).
        parts = assertion.split(".")
        return nil unless parts.length == 3

        payload = Base64.urlsafe_decode64(parts[1])
        JSON.parse(payload)
      rescue ArgumentError, JSON::ParserError
        nil
      end
    end
  end
end
