# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART Backend Services OAuth token endpoint
    # ONC 170.315(g)(10)(vi) - Backend services authorization
    #
    # Test authorization server for the engine. Supports:
    #   - client_credentials with a JWT client_assertion
    #   - SMART launch context resolution (launch token -> patient/encounter)
    #   - refresh_token grant with rotation
    #   - RFC 7662 token introspection
    #
    # PHI safety: token responses carry identifiers only (patient DFN,
    # encounter id, client uid). Names, DOB, SSN, and clinical data are
    # never included in token payloads or logged here.
    class BackendServicesController < ActionController::API
      TOKEN_TTL = 3600

      def token
        case params[:grant_type]
        when "client_credentials"
          issue_client_credentials_token
        when "refresh_token"
          rotate_refresh_token
        else
          render json: { error: "unsupported_grant_type" }, status: :bad_request
        end
      end

      # RFC 7662 token introspection.
      def introspect
        unless params[:token].present?
          render json: { error: "invalid_request", error_description: "token is required" },
                 status: :bad_request
          return
        end

        app = authenticate_introspection_caller
        return unless app

        token = Doorkeeper::AccessToken.by_token(params[:token])
        active = token.present? && !token.revoked? && !token.expired?

        render json: introspection_payload(token, app, active), status: :ok
      end

      private

      def issue_client_credentials_token
        unless params[:client_assertion].present?
          render json: { error: "invalid_client", error_description: "client_assertion is required" },
                 status: :bad_request
          return
        end

        app = authenticate_client_assertion
        return unless app

        launch_context = nil
        if params[:launch].present?
          launch_context = resolve_launch_context(app)
          return unless launch_context
        end

        token = create_token(
          application: app,
          scopes: params[:scope] || "system/*.read",
          resource_owner_id: launch_context&.patient_dfn
        )

        record_security_event(action: "C", application: app)
        render json: token_response(token, launch_context: launch_context), status: :ok
      end

      def rotate_refresh_token
        unless params[:refresh_token].present?
          render json: { error: "invalid_request", error_description: "refresh_token is required" },
                 status: :bad_request
          return
        end

        app = authenticate_client_assertion
        return unless app

        old_token = Doorkeeper::AccessToken.by_refresh_token(params[:refresh_token])

        if old_token.nil? || old_token.revoked? || old_token.application_id != app.id
          render json: { error: "invalid_grant", error_description: "Invalid refresh token" },
                 status: :bad_request
          return
        end

        old_token.revoke
        token = create_token(
          application: app,
          scopes: old_token.scopes.to_s,
          resource_owner_id: old_token.resource_owner_id
        )

        record_security_event(action: "U", application: app)
        render json: token_response(token), status: :ok
      end

      def authenticate_client_assertion
        claims = decode_jwt(params[:client_assertion])
        unless claims
          render json: { error: "invalid_client", error_description: "Invalid JWT assertion" },
                 status: :unauthorized
          return nil
        end

        app = Doorkeeper::Application.find_by(uid: claims["iss"])
        unless app
          render json: { error: "invalid_client", error_description: "Unknown client" },
                 status: :unauthorized
          return nil
        end

        app
      end

      def authenticate_introspection_caller
        app = Doorkeeper::Application.find_by(uid: params[:client_id].to_s)
        unless app
          render json: { error: "invalid_client", error_description: "Unknown client" },
                 status: :unauthorized
          return nil
        end

        app
      end

      # Resolve a SMART launch token minted by the host app. The launch
      # token must belong to the requesting client and be unexpired.
      def resolve_launch_context(app)
        context = LaunchContext.resolve(params[:launch])

        if context.nil?
          render json: { error: "invalid_grant", error_description: "Unknown or expired launch token" },
                 status: :bad_request
          return nil
        end

        if context.oauth_application_uid != app.uid
          render json: { error: "invalid_grant", error_description: "Launch token was not minted for this client" },
                 status: :bad_request
          return nil
        end

        context
      end

      def create_token(application:, scopes:, resource_owner_id: nil)
        Doorkeeper::AccessToken.create!(
          application: application,
          resource_owner_id: resource_owner_id,
          scopes: scopes,
          expires_in: TOKEN_TTL,
          use_refresh_token: true
        )
      end

      # SMART token response: access token plus launch context claims.
      # Only identifiers (patient DFN, encounter id) — never PHI.
      def token_response(token, launch_context: nil)
        response = {
          access_token: token.plaintext_token || token.token,
          token_type: "bearer",
          expires_in: TOKEN_TTL,
          scope: token.scopes.to_s
        }
        response[:refresh_token] = token.plaintext_refresh_token if token.plaintext_refresh_token.present?

        if launch_context
          response.merge!(launch_context.to_smart_context)
        elsif token.resource_owner_id.present?
          response[:patient] = token.resource_owner_id.to_s
        end

        response
      end

      def introspection_payload(token, app, active)
        return { active: false } unless active

        payload = {
          active: true,
          scope: token.scopes.to_s,
          client_id: app.uid,
          token_type: "bearer",
          exp: token.created_at.to_i + token.expires_in.to_i
        }
        payload[:patient] = token.resource_owner_id.to_s if token.resource_owner_id.present?
        payload
      end

      # PHI-safe security audit: the OAuth client uid is hashed, no token
      # values or patient context are written to the audit row.
      def record_security_event(action:, application:)
        AuditEvent.create!(
          event_type: "security",
          action: action,
          outcome: "0",
          entity_type: "OAuthClient",
          entity_identifier: VistaRpc::PhiSanitizer.hash_identifier(application.uid),
          backend_identifier: Lakeraven::EHR.configuration.backend.to_s,
          agent_who_type: "Application",
          agent_who_identifier: application.uid,
          agent_network_address: request.remote_ip
        )
      rescue => e
        Rails.logger.error(VistaRpc::PhiSanitizer.sanitize_message("AuditEvent write failed: #{e.message}"))
      end

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
