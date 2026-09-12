# frozen_string_literal: true

module Lakeraven
  module EHR
    class AllergyIntolerancesController < ApplicationController
      include PatientCompartment

      def index
        dfn = patient_compartment_dfn
        results = AllergyIntolerance.for_patient(dfn)
        render_bundle(results.map { |r| { resourceType: "AllergyIntolerance" }.merge(r) })
      end

      def show
        render_not_found("AllergyIntolerance", params[:id])
      end
    end
  end
end
