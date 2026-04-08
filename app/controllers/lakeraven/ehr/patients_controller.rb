# frozen_string_literal: true

module Lakeraven
  module EHR
    # FHIR R4 Patient resource controller.
    #
    # GET /Patient/:identifier — read by opaque token.
    #
    # Auth: requires a Bearer token (per SmartAuthentication) with a
    # patient/Patient.read, user/Patient.read, or system/Patient.read
    # scope. For patient-context tokens (patient/ scope), the bound
    # patient must match the requested identifier.
    class PatientsController < ApplicationController
      include SmartAuthentication
      include AuditableClinicalAccess

      before_action :authenticate_smart_token!
      before_action :require_patient_read_scope!, only: :show
      before_action :enforce_patient_context!, only: :show

      audit_clinical_access only: :show

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

      private

      # Allow any of patient/Patient.read, user/Patient.read,
      # system/Patient.read, or their wildcards.
      def require_patient_read_scope!
        authorize_resource_read!("Patient")
      end

      def enforce_patient_context!
        authorize_patient_context!(params[:identifier])
      end
    end
  end
end
