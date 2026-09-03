# frozen_string_literal: true

module Lakeraven
  module EHR
    class EncountersController < ApplicationController
      include FHIRDateSearch

      # Org-bound credentials: authorization binds to the patient RESOLVED
      # from ?patient=, at the result level (SmartAuthentication). #show
      # authorizes at the result level itself — the owning patient resolves
      # from the found encounter, never from a request parameter.
      organization_scope :resolved_patient, only: :index, dfn_param: :patient
      organization_scope :result_filtered, only: :show
      before_action :require_patient_param, only: :index

      def index
        dfn = params[:patient].to_s.delete_prefix("Patient/")
        encounters = Encounter.from_appointment_hashes(Encounter.for_patient(dfn), patient_dfn: dfn)
        encounters += EncounterStore.instance.for_patient(dfn)
        # `date=ge{date}` + `_sort=-date` on period.start (FHIRDateSearch).
        encounters = filter_by_fhir_date(encounters, &:period_start)
        encounters = sort_by_fhir_date(encounters, &:period_start)
        render_bundle(encounters.map(&:to_fhir))
      end

      def show
        encounter = EncounterStore.instance.find(params[:id])
        return render_not_found("Encounter", params[:id]) unless encounter

        # Result-level org enforcement: an org-bound credential reads an
        # encounter only when its organization manages the owning patient.
        if organization_bound?
          return unless authorize_resolved_patient!(encounter.patient_identifier || encounter.patient_dfn)
        end

        render_fhir(encounter.to_fhir)
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
