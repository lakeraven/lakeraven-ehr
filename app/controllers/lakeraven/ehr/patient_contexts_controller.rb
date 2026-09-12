# frozen_string_literal: true

module Lakeraven
  module EHR
    # Opening a patient's record in the clinician session.
    #
    # One deliberate, audited act — the counterpart of CPRS patient selection.
    # Everything session-authenticated that reads a patient's clinical data
    # requires the context this creates (ClinicianPatientContext).
    #
    # It runs on the same SMART token as the rest of the surface: opening a
    # record is itself a clinical access, so a credential that may not read
    # screenings may not open the record either.
    class PatientContextsController < WebController
      include BrowserSmartAuthentication
      include FailClosedClinicalAudit
      include ClinicianPatientContext

      before_action :authenticate_smart_token!
      before_action :authorize_context_scope!
      before_action :enforce_token_patient_context!

      def create
        open_patient_context!(params[:dfn])
        # Fixed internal destination: never a caller-supplied return path, so
        # this cannot be used as an open redirect.
        redirect_to patient_screenings_path(params[:dfn])
      end

      private

      def authorize_context_scope!
        return true if can_read?(ScreeningsController::SCREENING_RESOURCE)

        render_forbidden("Insufficient scope to open this patient's record")
        false
      end

      def enforce_token_patient_context! = authorize_patient_context!(params[:dfn])

      # An open that the audit log has no record of must not survive the
      # request: the whole value of this step is that it is attributable.
      def rollback_unrecorded_access
        close_patient_context!
      end

      def audit_action = "E"
      def fhir_resource_type = "Patient"

      def audit_agent_attributes
        duz = current_token&.resource_owner_id.to_s.presence
        return super if duz.blank?

        { agent_who_type: "Practitioner", agent_who_identifier: duz }
      end
    end
  end
end
