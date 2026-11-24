# frozen_string_literal: true

module Lakeraven
  module EHR
    class ServiceRequestsController < ApplicationController
      disclosure_surface :fhir_api
      include PatientScopedRead

      private

      def patient_resources(dfn)
        ServiceRequest.for_patient(dfn).map { |row| ServiceRequest.from_rpms_row(row, patient_dfn: dfn).to_fhir }
      end
    end
  end
end
