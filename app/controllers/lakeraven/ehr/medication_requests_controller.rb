# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequestsController < ApplicationController
      include PatientCompartment

      rate_limit only: %i[index show]

      compartment_bound :index, param: :patient, require_param: true

      # status and intent are token parameters: FHIRSearchBundle filters the
      # served resources on them (FHIR::SearchCapabilities), system included.
      def index
        dfn = patient_compartment_dfn
        resources = MedicationRequest.for_patient(dfn).map { |r| MedicationRequest.from_rpms_row(r, patient_dfn: dfn) }
        render_bundle_egress(resources.map(&:to_fhir))
      end

      def show
        render_not_found("MedicationRequest", params[:id])
      end
    end
  end
end
