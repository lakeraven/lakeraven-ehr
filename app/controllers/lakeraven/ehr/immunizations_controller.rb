# frozen_string_literal: true

module Lakeraven
  module EHR
    class ImmunizationsController < ApplicationController
      include PatientCompartment

      def index
        dfn = patient_compartment_dfn
        render_bundle(Immunization.for_patient(dfn).map(&:to_fhir))
      end
    end
  end
end
