# frozen_string_literal: true

module Lakeraven
  module EHR
    class DiagnosticReportsController < ApplicationController
      include FHIRDateSearch

      # Org-bound credentials: authorization binds to the patient RESOLVED
      # from ?patient=, at the result level (SmartAuthentication). #show
      # authorizes at the result level itself — the owning patient resolves
      # from the found report, never from a request parameter.
      organization_scope :resolved_patient, only: :index, dfn_param: :patient
      organization_scope :result_filtered, only: :show
      before_action :require_patient_param, only: :index

      # DiagnosticReport is fixture-served (DiagnosticReportStore) — there
      # is no verified live RPC read path for lab report panels.
      def index
        dfn = extract_patient_dfn(params[:patient])
        reports = servable(DiagnosticReportStore.instance.for_patient(dfn))
        # `date=ge{date}` + `_sort=-date` on effectiveDateTime (FHIRDateSearch).
        reports = filter_by_fhir_date(reports, &:effective_datetime)
        reports = sort_by_fhir_date(reports, &:effective_datetime)
        render_bundle(reports.map(&:to_fhir))
      end

      # Resolves the same store the search serves, so every id a search
      # returns is readable. Org-bound credentials are authorized against
      # the RESOLVED resource's owning patient: a foreign patient's report
      # id is a 403 (never disclosed), an unknown id a 404.
      def show
        report = DiagnosticReportStore.instance.find(params[:id])
        report = nil unless report&.code_present? # a codeless record is never served (it was never searchable either)
        return render_not_found("DiagnosticReport", params[:id]) unless report

        # Patient-context tokens read only their own compartment (403 on a
        # foreign patient's resource); org-bound credentials are authorized
        # against the resolved owner's organization.
        return unless authorize_patient_context!(report.patient_dfn)
        if organization_bound?
          return unless authorize_resolved_patient!(report.patient_dfn)
        end

        render_fhir(report.to_fhir)
      end

      private

      # DiagnosticReport.code is 1..1: a record with no source naming cannot
      # be emitted as valid FHIR, so it is OMITTED from results rather than
      # served invalid (DiagnosticReport#code_present?).
      def servable(reports)
        reports.select(&:code_present?)
      end

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
