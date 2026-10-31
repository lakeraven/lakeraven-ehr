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
    # record is itself a clinical access, so it takes a read of the chart
    # (Patient, as the patient bar opens it: rpms-ux S-CHT-01) or of the
    # screenings. Each page the open leads to still checks its own scope.
    class PatientContextsController < WebController
      # Fail-closed audit comes from WebController's AuditableClinicalAccess
      # (#512): an open that cannot be recorded is not completed.
      include BrowserSmartAuthentication
      include ClinicianPatientContext

      before_action :authenticate_smart_token!
      before_action :authorize_context_scope!
      before_action :enforce_token_patient_context!

      def create
        open_patient_context!(params[:dfn])
        # Fixed internal destinations: never a caller-supplied return path, so
        # this cannot be used as an open redirect. The chart when the user may
        # read it, otherwise the screenings, where this open began.
        redirect_to(can_read?("Patient") ? patient_chart_path(params[:dfn]) : patient_screenings_path(params[:dfn]))
      end

      private

      def authorize_context_scope!
        return true if can_read?("Patient") || can_read?(ScreeningsController::SCREENING_RESOURCE)

        render_forbidden("Insufficient scope to open this patient's record")
        false
      end

      def enforce_token_patient_context! = authorize_patient_context!(params[:dfn])

      # An open that the audit log has no record of must not survive the
      # request: the whole value of this step is that it is attributable.
      def rollback_unrecorded_access
        close_patient_context!
      end

      # Opening a record is an Execute, not the Create the verb map would
      # infer from the POST. Practitioner attribution comes from the shared
      # resolver via #486's `browser_sso_token?`/`current_duz`.
      def audit_action = "E"
      def fhir_resource_type = "Patient"

      # The patient is the route segment. A query-string id or dfn is not
      # the record this open named.
      # Opening "01" is opening patient 1. The session keeps the raw segment
      # (ClinicianPatientContext compares it as stored); the audit row names
      # the canonical dfn the repository resolves.
      def direct_audit_identifier
        Patient.canonical_dfn(route_param(:dfn)) || route_param(:dfn) || super
      end
    end
  end
end
