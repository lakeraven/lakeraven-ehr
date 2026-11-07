# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequestsController < ApplicationController
      include PatientScopedRead

      disclosure_surface :fhir_api

      # status and intent are token parameters: FHIRSearchBundle filters the
      # served resources on them (FHIR::SearchCapabilities), system included.

      private

      def patient_resources(dfn)
        MedicationRequest.for_patient(dfn).map { |row| MedicationRequest.from_rpms_row(row, patient_dfn: dfn).to_fhir }
      end
    end
  end
end
