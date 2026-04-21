# frozen_string_literal: true

module Lakeraven
  module EHR
    class ConditionsController < ApplicationController
      before_action :require_patient_param, only: :index

      def index
        dfn = extract_patient_dfn(params[:patient])
        results = Condition.for_patient(dfn)
        render_bundle(results.map { |r| { resourceType: "Condition" }.merge(r) })
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
