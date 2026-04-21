# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationController < ActionController::API
      FHIR_CONTENT_TYPE = "application/fhir+json"

      private

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
