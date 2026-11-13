# frozen_string_literal: true

module Lakeraven
  module EHR
    class ImmunizationsController < ApplicationController
      include PatientScopedRead

      disclosure_surface :fhir_api

      private

      def patient_resources(dfn)
        Immunization.for_patient(dfn).map(&:to_fhir)
      end
    end
  end
end
