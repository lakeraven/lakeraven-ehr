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

        scope_permits?(resource_type, %w[read *])
      end

      # Authorization for the CURRENT request's HTTP verb. A read scope must
      # never authorize a write: GET/HEAD/OPTIONS need read, everything else
      # needs write.
      READ_METHODS = %w[GET HEAD OPTIONS].freeze

      def read_request?
        READ_METHODS.include?(request.request_method)
      end

      def can_perform?(resource_type)
        read_request? ? can_read?(resource_type) : can_write?(resource_type)
      end

      # Resource types pulled into a bundle by _include / _revinclude are
      # resources the caller is being handed, so they need the caller's scope
      # like any other read. Returns the subset the token may actually read.
      def readable_included_types(types)
        Array(types).select { |t| can_read?(t) }
      end

      # Check if token can write the given FHIR resource type (SMART v2).
      def can_write?(resource_type)
        return false unless current_token

        scope_permits?(resource_type, %w[write c *])
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

      # Compartment enforcement for INDEXES, SEARCHES and declared writes —
      # not just #show.
      #
      # A patient-bound token asking for a collection, or naming a patient in
      # a write, must either name its own compartment or be refused. Requiring
      # a parameter is not a control — `?patient=1` from a token bound to 999
      # returned patient 1's observations, and `patient_dfn=1` on a POST
      # returned patient 1's entire C-CDA. An operation that names no patient
      # at all is a cross-patient operation by definition, so a bound token
      # cannot issue one.
      def authorize_patient_search!(patient_id)
        return true unless patient_context_scope?

        if patient_id.blank?
          render_forbidden("A patient-scoped token must act within its own patient compartment")
          return false
        end

        authorize_patient_context!(patient_id)
      end

      private

      def scope_permits?(resource_type, actions)
        token_scopes = current_token.scopes.to_s.split
        allowed = %w[patient user system].flat_map do |context|
          actions.flat_map { |a| [ "#{context}/#{resource_type}.#{a}", "#{context}/*.#{a}" ] }
        end
        (token_scopes & allowed).any?
      end

      def extract_bearer_token
        auth = request.headers["Authorization"]
        return nil if auth.blank?

        match = auth.match(/\ABearer\s+(.+)\z/i)
        match&.captures&.first
      end

      def patient_context_scope?
        current_token&.scopes&.to_s&.match?(%r{\bpatient/})
      end

      def user_context_scope?
        current_token&.scopes&.to_s&.match?(%r{\buser/})
      end

      def system_scope?
        current_token&.scopes&.to_s&.match?(%r{\bsystem/})
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
