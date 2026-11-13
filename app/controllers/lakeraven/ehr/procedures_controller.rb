# frozen_string_literal: true

module Lakeraven
  module EHR
    class ProceduresController < ApplicationController
      include PatientScopedRead

      disclosure_surface :fhir_api

      private

      def patient_resources(dfn)
        Procedure.for_patient(dfn).map { |row| Procedure.from_rpms_row(row, patient_dfn: dfn).to_fhir }
      end
    end
  end
end
