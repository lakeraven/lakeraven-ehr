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
        # Per-action organization-scoping declarations (see .organization_scope).
        class_attribute :organization_scope_rules, instance_writer: false, default: {}
      end

      class_methods do
        # Declares how actions satisfy per-organization credential scoping
        # (enforced by #enforce_organization_scope!). Rules:
        #
        #   :resolved_patient — resolve params[dfn_param] to a Patient and
        #       require the credential's organization to manage that patient.
        #       Fail closed: a blank or unresolvable patient reference is
        #       denied (clinical gateways can hold records for a DFN the
        #       Patient lookup cannot resolve).
        #   :result_filtered — the action itself authorizes at the RESULT
        #       level (filters resolved patients by organization, or enforces
        #       resolved-resource ownership). Declare only alongside such code.
        #   :not_patient_compartment — the resource carries no per-patient
        #       PHI (directory/terminology data); allowed for any credential.
        #
        # Any action WITHOUT a declaration is denied to org-bound credentials
        # outright, so a new endpoint cannot leak cross-organization data by
        # omission.
        def organization_scope(rule, only:, dfn_param: nil)
          entries = Array(only).to_h { |a| [ a.to_sym, { rule: rule, dfn_param: dfn_param } ] }
          self.organization_scope_rules = organization_scope_rules.merge(entries)
        end
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

      # -- Per-organization credential scoping --------------------------------
      # Vardana source-system profile section 2 / conformance item 2: a
      # credential bound to one organization must not reach another
      # organization's patients. Binding lives on the Doorkeeper application
      # (organization_id); a nil binding means the credential is not org-bound.

      def current_organization_id
        current_token&.application&.organization_id
      end

      def organization_bound?
        current_organization_id.present?
      end

      # Before-action: fail-closed enforcement for org-bound credentials.
      # Authorization binds to the RESOLVED patient / result set — never to a
      # request parameter name (an earlier version inferred the patient from
      # dfn/patient/_id params, which any differently-named parameter or
      # unlisted endpoint bypassed; independent security review finding).
      def enforce_organization_scope!
        return true unless organization_bound?

        entry = organization_scope_rules[action_name.to_sym]
        case entry&.dig(:rule)
        when :not_patient_compartment, :result_filtered
          true
        when :resolved_patient
          authorize_resolved_patient!(params[entry[:dfn_param]])
        else
          render_forbidden("This endpoint is not available to organization-scoped credentials")
          false
        end
      end

      # Resolves the addressed patient and requires the credential's
      # organization to manage them. Fail closed: a blank or unresolvable
      # patient reference is denied — clinical gateways may hold records for
      # a DFN the Patient lookup cannot resolve, and those must never be
      # readable across organizations.
      def authorize_resolved_patient!(raw_dfn)
        dfn = raw_dfn.to_s.sub(%r{\APatient/}, "")
        patient = dfn.present? ? Patient.find_by_dfn(dfn) : nil
        return authorize_organization_for_patient!(patient) if patient

        render_forbidden("Credential is not authorized for this patient's organization")
        false
      end

      def authorize_organization_for_patient!(patient)
        return true unless organization_bound?
        return true if organization_permits_patient?(patient)

        render_forbidden("Credential is not authorized for this patient's organization")
        false
      end

      # Fail closed: a patient whose managing organization cannot be resolved
      # is not readable by an org-bound credential.
      def organization_permits_patient?(patient)
        site_ien = patient.respond_to?(:site_ien) ? patient.site_ien : nil
        return false if site_ien.blank?

        [ site_ien.to_s, "rpms-organization-#{site_ien}" ].include?(current_organization_id.to_s)
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
