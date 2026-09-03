# frozen_string_literal: true

module Lakeraven
  module EHR
    class DiagnosticReportsController < ApplicationController
      include FHIRDateSearch

      # Org-bound credentials: authorization binds to the patient RESOLVED
      # from ?patient=, at the result level (SmartAuthentication).
      organization_scope :resolved_patient, only: :index, dfn_param: :patient
      before_action :require_patient_param, only: :index

      def index
        dfn = extract_patient_dfn(params[:patient])
        reports = DiagnosticReport.from_report_hashes(DiagnosticReport.for_patient(dfn), patient_dfn: dfn)
        # `date=ge{date}` + `_sort=-date` on effectiveDateTime (FHIRDateSearch).
        reports = filter_by_fhir_date(reports, &:effective_datetime)
        reports = sort_by_fhir_date(reports, &:effective_datetime)
        render_bundle(reports.map(&:to_fhir))
      end

      def show
        render_not_found("DiagnosticReport", params[:id])
      end

      private

      def require_patient_param
        return if params[:patient].present?

        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "required",
          diagnostics: "Search parameter 'patient' is required"
        )
      end

      def extract_patient_dfn(param)
        param.to_s.delete_prefix("Patient/")
      end
    end
  end
end
