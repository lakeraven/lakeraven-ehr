# frozen_string_literal: true

module Lakeraven
  module EHR
    class PatientsController < ApplicationController
      before_action :enforce_patient_context!, only: :show

      def index
        patients = if params[:name].present?
          Patient.search(params[:name])
        else
          Patient.search("")
        end

        render_bundle(patients.map(&:to_fhir))
      end

      def show
        patient = Patient.find_by_dfn(params[:dfn])

        if patient.nil?
          render_operation_outcome(
            status: :not_found,
            severity: "error",
            code: "not-found",
            diagnostics: "Patient not found"
          )
          return
        end

        render_fhir(patient.to_fhir)
      end

      private

      def enforce_patient_context!
        authorize_patient_context!(params[:dfn])
      end
    end
  end
end
