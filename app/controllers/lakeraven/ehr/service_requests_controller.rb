# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequestsController < ApplicationController
      # Org-bound credentials: authorization binds to the patient RESOLVED
      # from ?patient=, at the result level (SmartAuthentication).
      organization_scope :resolved_patient, only: :index, dfn_param: :patient
      before_action :require_patient_param, only: :index

      def index
        dfn = params[:patient].to_s.delete_prefix("Patient/")
        results = ServiceRequest.for_patient(dfn)
        render_bundle(results.map { |r| { resourceType: "ServiceRequest" }.merge(r) })
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
