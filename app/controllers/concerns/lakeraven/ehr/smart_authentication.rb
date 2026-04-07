# frozen_string_literal: true

module Lakeraven
  module EHR
    # Bearer-token authentication and SMART scope authorization for
    # FHIR controllers.
    #
    # Usage:
    #
    #   class Lakeraven::EHR::PatientsController < ApplicationController
    #     include Lakeraven::EHR::SmartAuthentication
    #     before_action :authenticate_smart_token!
    #     before_action -> { authorize_scope!("patient/Patient.read") }, only: :show
    #   end
    #
    # All error responses are FHIR OperationOutcome resources rendered
    # as application/fhir+json. Reuses Lakeraven::EHR::FHIR::OperationOutcome
    # so the wire format is consistent with the rest of the engine.
    #
    # Reference: http://hl7.org/fhir/smart-app-launch/scopes-and-launch-context.html
    module SmartAuthentication
      extend ActiveSupport::Concern

      FHIR_CONTENT_TYPE = "application/fhir+json"

      included do
        attr_reader :current_token
      end

      # Validate the Authorization: Bearer <token> header. Renders a
      # 401 OperationOutcome with code "login" if the token is missing,
      # malformed, expired, or revoked.
      def authenticate_smart_token!
        token_value = extract_bearer_token
        if token_value.nil? || token_value.empty?
          return render_login_error("No Bearer token provided")
        end

        @current_token = Doorkeeper::AccessToken.by_token(token_value)
        if @current_token.nil? || @current_token.revoked?
          return render_login_error("Invalid or revoked token")
        end
        if @current_token.expired?
          return render_login_error("Token has expired")
        end
        true
      end

      # Authorize the current token against a SMART scope string. Returns
      # true on success; renders a 403 OperationOutcome with code
      # "forbidden" and returns false on failure.
      def authorize_scope!(required_scope)
        return true if current_token&.scopes&.include?(required_scope)
        return true if wildcard_scope_matches?(required_scope)

        render_forbidden("Insufficient scope: #{required_scope}")
        false
      end

      private

      def extract_bearer_token
        header = request.headers["Authorization"].to_s
        match = header.match(/\ABearer\s+(.+)\z/i)
        match && match[1]
      end

      # Match a required scope like "patient/Patient.read" against the
      # token's scope list, allowing wildcards in either the resource
      # or the permission slot, plus system/* fallthrough.
      def wildcard_scope_matches?(required_scope)
        return false unless current_token

        match = required_scope.match(%r{\A(patient|user|system)/([^.]+)\.(.+)\z})
        return false unless match

        context, _resource, perm = match.captures
        wildcards = [
          "#{context}/*.#{perm}",
          "#{context}/*.read",
          "#{context}/*.*",
          "system/*.read",
          "system/*.*"
        ]
        wildcards.any? { |w| current_token.scopes.include?(w) }
      end

      def render_login_error(message)
        outcome = FHIR::OperationOutcome.call(
          severity: "error",
          code: "login",
          diagnostics: message
        )
        render json: outcome, status: :unauthorized, content_type: FHIR_CONTENT_TYPE
      end

      def render_forbidden(message)
        outcome = FHIR::OperationOutcome.call(
          severity: "error",
          code: "forbidden",
          diagnostics: message
        )
        render json: outcome, status: :forbidden, content_type: FHIR_CONTENT_TYPE
      end
    end
  end
end
