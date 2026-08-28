# frozen_string_literal: true

# SMART on FHIR Authentication Concern
# ONC § 170.315(g)(10) — Bearer token auth + scope-based authorization.
#
# Ported from rpms_redux SmartAuthentication.
module Lakeraven
  module EHR
    module SmartAuthentication
      extend ActiveSupport::Concern

      included do
        attr_reader :current_token
      end

      def authenticate_smart_token!
        token_string = extract_bearer_token

        if token_string.blank?
          render_unauthorized("No Bearer token provided")
          return
        end

        @current_token = Doorkeeper::AccessToken.by_token(token_string)

        if @current_token.nil? || @current_token.revoked?
          render_unauthorized("Invalid or revoked token")
          return
        end

        if @current_token.expired?
          render_unauthorized("Token has expired")
          return
        end

        true
      end

      # Check if token can read the given FHIR resource type.
      def can_read?(resource_type)
        return false unless current_token

        token_scopes = current_token.scopes.to_s.split
        allowed = [
          "patient/#{resource_type}.read", "patient/#{resource_type}.*",
          "patient/*.read", "patient/*.*",
          "user/#{resource_type}.read", "user/#{resource_type}.*",
          "user/*.read", "user/*.*",
          "system/#{resource_type}.read", "system/#{resource_type}.*",
          "system/*.read", "system/*.*"
        ]
        (token_scopes & allowed).any?
      end

      # Check if token can write the given FHIR resource type (SMART v2).
      def can_write?(resource_type)
        return false unless current_token

        token_scopes = current_token.scopes.to_s.split
        allowed = [
          "patient/#{resource_type}.write", "patient/#{resource_type}.c", "patient/#{resource_type}.*",
          "patient/*.write", "patient/*.c", "patient/*.*",
          "user/#{resource_type}.write", "user/#{resource_type}.c", "user/#{resource_type}.*",
          "user/*.write", "user/*.c", "user/*.*",
          "system/#{resource_type}.write", "system/#{resource_type}.c", "system/#{resource_type}.*",
          "system/*.write", "system/*.c", "system/*.*"
        ]
        (token_scopes & allowed).any?
      end

      # Enforce patient compartment for patient-context tokens.
      #
      # Binding is checked whenever the token carries ANY patient/ scope: a
      # mixed-scope token (patient/ alongside system/ or user/) stays bound to
      # its patient compartment — broader scopes must not bypass the binding
      # (independent security review finding). Tokens with no patient/ scope
      # (pure system/, user/, or non-clinical scopes) are unbound.
      def authorize_patient_context!(patient_id)
        return true unless patient_context_scope?

        bound = current_token.resource_owner_id.to_s
        if bound.blank? || bound != patient_id.to_s
          render_forbidden("Patient context mismatch")
          return false
        end

        true
      end

      private

      def extract_bearer_token
        auth = request.headers["Authorization"]
        return nil if auth.blank?

        match = auth.match(/\ABearer\s+(.+)\z/i)
        match&.captures&.first
      end

      def patient_context_scope?
        current_token&.scopes&.to_s&.match?(%r{\bpatient/})
      end

      def render_unauthorized(message = "Unauthorized")
        render json: {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "login", diagnostics: message } ]
        }, status: :unauthorized, content_type: "application/fhir+json"
      end

      def render_forbidden(message = "Forbidden")
        render json: {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "forbidden", diagnostics: message } ]
        }, status: :forbidden, content_type: "application/fhir+json"
      end
    end
  end
end
