# frozen_string_literal: true

module Lakeraven
  module EHR
    class ObservationsController < ApplicationController
      include PatientScopedRead

      disclosure_surface :fhir_api

      # category and code are token parameters: FHIRSearchBundle filters the
      # served resources on them (FHIR::SearchCapabilities), system included.

      private

      def patient_resources(dfn)
        SupplementalClinicalResources.merged_observations_for_patient(dfn).map(&:to_fhir)
      end
    end
  end
end
