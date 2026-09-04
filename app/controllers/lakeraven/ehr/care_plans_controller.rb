# frozen_string_literal: true

module Lakeraven
  module EHR
    class CarePlansController < ApplicationController
      # Org-bound credentials: authorization binds to the patient RESOLVED
      # from ?patient=, at the result level (SmartAuthentication). #show
      # authorizes at the result level itself — the owning patient resolves
      # from the found plan, never from a request parameter.
      organization_scope :resolved_patient, only: :index, dfn_param: :patient
      organization_scope :result_filtered, only: :show
      before_action :require_patient_param, only: :index

      # CarePlan is fixture-served (CarePlanStore) — there is no verified
      # live RPC read path for care plans.
      def index
        dfn = extract_patient_dfn(params[:patient])
        care_plans = CarePlanStore.instance.for_patient(dfn)
        if params[:status].present?
          statuses = params[:status].split(",")
          care_plans = care_plans.select { |cp| statuses.include?(cp.status) }
        end
        render_bundle(care_plans.map(&:to_fhir))
      end

      # Resolves the same store the search serves, so every id a search
      # returns is readable. Org-bound credentials are authorized against
      # the RESOLVED resource's owning patient: a foreign patient's plan id
      # is a 403 (never disclosed), an unknown id a 404.
      def show
        care_plan = CarePlanStore.instance.find(params[:id])
        return render_not_found("CarePlan", params[:id]) unless care_plan

        # Patient-context tokens read only their own compartment (403 on a
        # foreign patient's resource); org-bound credentials are authorized
        # against the resolved owner's organization.
        return unless authorize_patient_context!(care_plan.patient_dfn)
        if organization_bound?
          return unless authorize_resolved_patient!(care_plan.patient_dfn)
        end

        render_fhir(care_plan.to_fhir)
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
