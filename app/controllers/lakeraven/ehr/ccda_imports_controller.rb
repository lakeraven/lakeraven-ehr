# frozen_string_literal: true

module Lakeraven
  module EHR
    # ONC §170.315(b)(1) — Transitions of Care (receive path)
    # ONC §170.315(b)(2) — Clinical Information Reconciliation (import)
    # Receives external C-CDA documents for reconciliation.
    class CcdaImportsController < ApplicationController
      # POST /ccda_imports
      # Import a C-CDA document for clinical reconciliation
      def create
        xml_string = request.body.read

        if xml_string.blank?
          return render_operation_outcome(
            status: :bad_request, severity: "error",
            code: "invalid", diagnostics: "Request body is empty"
          )
        end

        service = ClinicalReconciliationService.new
        result = service.import_from_ccda(
          patient_dfn: params[:patient_dfn],
          clinician_duz: params[:clinician_duz],
          xml_string: xml_string
        )

        if result.success?
          render json: {
            resourceType: "OperationOutcome",
            issue: [{
              severity: "information",
              code: "informational",
              diagnostics: "C-CDA imported successfully for reconciliation"
            }]
          }, status: :created, content_type: FHIR_CONTENT_TYPE
        else
          render_operation_outcome(
            status: :unprocessable_entity, severity: "error",
            code: "invalid", diagnostics: result.errors.join(", ")
          )
        end
      end
    end
  end
end
