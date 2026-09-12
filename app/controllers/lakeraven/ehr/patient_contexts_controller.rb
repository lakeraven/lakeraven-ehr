# frozen_string_literal: true

module Lakeraven
  module EHR
    # Opening a patient's record on the session-authenticated web surface.
    #
    # One deliberate, audited act — the counterpart of CPRS patient selection.
    # Everything session-authenticated that reads a patient's clinical data
    # requires the context this creates (ClinicianPatientContext).
    class PatientContextsController < WebController
      include SessionAuditedClinicalAccess
      include ClinicianPatientContext

      before_action :require_authentication
      before_action :require_clinical_access

      def create
        open_patient_context!(params[:dfn])
        # Fixed internal destination: never a caller-supplied return path, so
        # this cannot be used as an open redirect.
        redirect_to patient_screenings_path(params[:dfn])
      end

      private

      def audit_action = "E"
      def fhir_resource_type = "Patient"
    end
  end
end
