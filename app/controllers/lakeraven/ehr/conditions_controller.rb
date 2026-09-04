# frozen_string_literal: true

module Lakeraven
  module EHR
    class ConditionsController < ApplicationController
      before_action :require_patient_param, only: :index

      def index
        dfn = extract_patient_dfn(params[:patient])
        conditions = Condition.from_problem_hashes(Condition.for_patient(dfn), patient_dfn: dfn)
        conditions = filter_by_clinical_status(conditions)
        render_bundle(conditions.map(&:to_fhir))
      end

      def show
        render_not_found("Condition", params[:id])
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

      # §4: Condition?patient=&clinical-status=active
      def filter_by_clinical_status(conditions)
        status = params["clinical-status"].presence || params[:clinical_status].presence
        return conditions if status.blank?

        conditions.select { |c| c.clinical_status == status }
      end
    end
  end
end
