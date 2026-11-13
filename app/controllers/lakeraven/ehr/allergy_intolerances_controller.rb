# frozen_string_literal: true

module Lakeraven
  module EHR
    class AllergyIntolerancesController < ApplicationController
      include PatientScopedRead

      disclosure_surface :fhir_api

      private

      def patient_resources(dfn)
        SupplementalClinicalResources.merged_allergy_intolerances_for_patient(dfn).map(&:to_fhir)
      end
    end
  end
end
