# frozen_string_literal: true

module Lakeraven
  module EHR
    class EncountersController < ApplicationController
      include FHIRDateSearch

      before_action :require_patient_param, only: :index

      def index
        dfn = params[:patient].to_s.delete_prefix("Patient/")
        encounters = Encounter.from_appointment_hashes(EncounterGateway.for_patient(dfn), patient_dfn: dfn)
        encounters = apply_date_param(encounters, params[:date], &:period_start)
        encounters = apply_date_sort(encounters, params[:_sort], &:period_start)
        render_bundle(encounters.map(&:to_fhir))
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
