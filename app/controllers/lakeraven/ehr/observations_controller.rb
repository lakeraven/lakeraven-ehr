# frozen_string_literal: true

module Lakeraven
  module EHR
    class ObservationsController < ApplicationController
      include PatientCompartment

      rate_limit only: %i[index show]

      compartment_bound :index, param: :patient, require_param: true

      # category and code are token parameters: FHIRSearchBundle filters the
      # served resources on them (FHIR::SearchCapabilities), system included.
      def index
        dfn = patient_compartment_dfn
        observations = SupplementalClinicalResources.merged_observations_for_patient(dfn)
        render_bundle_egress(observations.map(&:to_fhir))
      end

      def show
        render_not_found("Observation", params[:id])
      end
    end
  end
end
