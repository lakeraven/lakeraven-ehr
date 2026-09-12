# frozen_string_literal: true

module Lakeraven
  module EHR
    class EncountersController < ApplicationController
      include PatientCompartment

      def index
        dfn = patient_compartment_dfn
        results = EncounterGateway.for_patient(dfn)
        render_bundle(results.map { |r| { resourceType: "Encounter" }.merge(r) })
      end
    end
  end
end
