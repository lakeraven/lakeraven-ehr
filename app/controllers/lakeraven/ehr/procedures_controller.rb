# frozen_string_literal: true

module Lakeraven
  module EHR
    class ProceduresController < ApplicationController
      before_action :require_patient_param, only: :index

      def index
        dfn = params[:patient].to_s.delete_prefix("Patient/")
        results = Procedure.for_patient(dfn)
        render_bundle(results.map(&:to_fhir))
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
    end
  end
end
