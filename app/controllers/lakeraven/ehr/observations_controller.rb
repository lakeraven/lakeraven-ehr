# frozen_string_literal: true

module Lakeraven
  module EHR
    class ObservationsController < ApplicationController
      before_action :require_patient_param, only: :index
      before_action :enforce_patient_context!, only: :index

      def index
        dfn = extract_patient_dfn(params[:patient])
        observations = Observation.fhir_for_patient(dfn)
        observations = filter_observations(observations)
        render_bundle(observations.map(&:to_fhir))
      end

      def show
        render_not_found("Observation", params[:id])
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

      def enforce_patient_context!
        return unless params[:patient].present?

        authorize_patient_context!(extract_patient_dfn(params[:patient]))
      end

      def filter_observations(observations)
        observations = observations.select { |o| o.category == params[:category] } if params[:category].present?
        if params[:code].present?
          codes = params[:code].split(",")
          observations = observations.select { |o| codes.include?(o.code) }
        end
        observations
      end
    end
  end
end
