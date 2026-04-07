# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 Patient resource controller.
    #
    # Handles GET /Patient/:identifier (read by opaque token).
    # Search via GET /Patient?... will land in a follow-up.
    class PatientsController < ApplicationController
      def show
        record = EHR.adapter.find_patient(
          tenant_identifier: Current.tenant_identifier,
          patient_identifier: params[:identifier]
        )

        if record.nil?
          render_operation_outcome(
            status: :not_found,
            severity: "error",
            code: "not-found",
            diagnostics: "Patient not found"
          )
          return
        end

        render_fhir(FHIR::PatientSerializer.call(record))
      end
    end
  end
end
