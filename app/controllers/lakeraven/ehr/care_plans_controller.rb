# frozen_string_literal: true

module Lakeraven
  module EHR
    class CarePlansController < ApplicationController
      # Org-bound credentials: authorization binds to the patient RESOLVED
      # from ?patient=, at the result level (SmartAuthentication).
      organization_scope :resolved_patient, only: :index, dfn_param: :patient
      before_action :require_patient_param, only: :index

      def index
        dfn = extract_patient_dfn(params[:patient])
        care_plans = CarePlan.from_rpc_hashes(CarePlan.for_patient(dfn), patient_dfn: dfn)
        if params[:status].present?
          statuses = params[:status].split(",")
          care_plans = care_plans.select { |cp| statuses.include?(cp.status) }
        end
        render_bundle(care_plans.map(&:to_fhir))
      end

      def show
        render_not_found("CarePlan", params[:id])
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
