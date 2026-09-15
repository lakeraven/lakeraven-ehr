# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationController < ActionController::API
      include SmartAuthentication
      include AuditableClinicalAccess

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_smart_token!
      before_action :authorize_fhir_scope!

      # Actions that DISCLOSE clinical data even though they are shaped as
      # writes — generating a C-CDA, running a bulk export, requesting an
      # eligibility determination.
      #
      # Verb dispatch alone gets these exactly backwards. Once POST means
      # "needs write", a token with no read scope anywhere can pull a patient's
      # name and DOB out of a transition of care while being refused
      # `GET /Patient`. They need BOTH: write for what they make, read for what
      # they hand back.
      #
      # `reads:` NAMES THE TYPES IN THE PAYLOAD, and is mandatory. An earlier
      # version checked `can_read?(fhir_resource_type)`, and that type comes
      # from the CONTROLLER CLASS NAME — "TransitionsOfCare", "Export" — which
      # is not a FHIR resource and is not what is being handed back. A token
      # scoped `system/TransitionsOfCare.read+write` satisfied it and still
      # extracted a patient's name and DOB. Only a token with no read scope at
      # all was caught.
      #
      # ChartsController has the same shape: it requires Patient read for the
      # whole request and gates each section on its own type.
      def self.discloses_clinical_data(*actions, reads:)
        types = Array(reads).freeze
        raise ArgumentError, "discloses_clinical_data needs the types it discloses" if types.empty?

        before_action(only: actions) { authorize_disclosing_write!(types) }
      end

      private

      # Write scope for the operation, read scope for EVERY type it discloses.
      def authorize_disclosing_write!(disclosed_types)
        unless can_write?(fhir_resource_type)
          return render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
        end

        missing = disclosed_types.reject { |type| can_read?(type) }
        return if missing.empty?

        render_forbidden("Insufficient scope for reading #{missing.join(', ')}")
      end

      def fhir_resource_type
        self.class.name.demodulize.delete_suffix("Controller").singularize
      end

      # Verb-aware. A read scope authorizes reads; anything that changes state
      # needs a write scope. This used to call can_read? for every verb, so a
      # `system/*.read` token could POST a C-CDA import, create and delete a
      # bulk export, run an eligibility check, and generate a transition of
      # care — all state changes behind a read-only credential.
      def authorize_fhir_scope!
        return if can_perform?(fhir_resource_type)

        if read_request?
          render_forbidden("Insufficient scope for reading #{fhir_resource_type}")
        else
          render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
        end
      end

      def authorize_fhir_write_scope!
        return if can_write?(fhir_resource_type)

        render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
      end

      def render_operation_outcome(status:, severity:, code:, diagnostics: nil)
        outcome = {
          resourceType: "OperationOutcome",
          issue: [ { severity: severity, code: code, diagnostics: diagnostics }.compact ]
        }
        render json: outcome, status: status, content_type: FHIR_CONTENT_TYPE
      end

      def render_fhir(resource, status: :ok)
        render json: resource, status: status, content_type: FHIR_CONTENT_TYPE
      end

      def render_not_found(resource_type, id)
        render_operation_outcome(
          status: :not_found,
          severity: "error",
          code: "not-found",
          diagnostics: "#{resource_type}/#{id} not found"
        )
      end

      def render_bundle(entries, type: "searchset")
        bundle = {
          resourceType: "Bundle",
          type: type,
          total: entries.length,
          entry: entries.map { |e| { resource: e } }
        }
        render json: bundle, status: :ok, content_type: FHIR_CONTENT_TYPE
      end
    end
  end
end
