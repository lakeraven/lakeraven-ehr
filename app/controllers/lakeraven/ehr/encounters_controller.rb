# frozen_string_literal: true

module Lakeraven
  module EHR
    # A US Core Encounter is a visit, not an appointment: the V files hang
    # from the visit, so the visit is what a diagnosis or a launch names.
    class EncountersController < ApplicationController
      include PatientScopedRead

      disclosure_surface :fhir_api

      private

      def patient_resources(dfn)
        EncounterGateway.visits(dfn).map { |row| Encounter.from_rpms_visit(row, patient_dfn: dfn).to_fhir }
      end
    end
  end
end
