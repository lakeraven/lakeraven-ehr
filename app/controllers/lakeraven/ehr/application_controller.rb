# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationController < ActionController::API
      include SmartAuthentication
      include AuditableClinicalAccess

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_smart_token!
      before_action :authorize_fhir_scope!

      private

      def fhir_resource_type
        self.class.name.demodulize.delete_suffix("Controller").singularize
      end

      # WHICH RECORD the audit row points at (S11 on #507).
      #
      # A FHIR search names its patient with `?patient=…` — Observation,
      # Condition, MedicationRequest, all of them — and the first version of
      # this method looked only at :dfn/:ien/:id, so every clinical search
      # was recorded with a NULL entity: `/audit-review?entity=<dfn>` came
      # back empty, and empty reads as "nobody opened this chart". Absence
      # of data presented as determination.
      #
      # The entity is recorded as a COHERENT reference: with a direct :id or
      # :ien the row names this controller's own resource; with only a
      # `?patient=` search parameter it names the PATIENT whose record was
      # searched — never `<Type>/<dfn>`, which would point at a different
      # record of the wrong type.
      def audit_entity_identifier
        params[:id].presence || params[:ien].presence || params[:dfn].presence || params[:patient].presence
      end

      def audit_entity_type
        return "Patient" if patient_scoped_search?

        fhir_resource_type
      end

      def patient_scoped_search?
        params[:id].blank? && params[:ien].blank? && params[:dfn].blank? && params[:patient].present?
      end

      def authorize_fhir_scope!
        return if can_read?(fhir_resource_type)

        render_forbidden("Insufficient scope for reading #{fhir_resource_type}")
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
