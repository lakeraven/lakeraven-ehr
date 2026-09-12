# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationRequestsController < ApplicationController
      include PatientCompartment

      def index
        dfn = patient_compartment_dfn
        results = MedicationRequest.for_patient(dfn)
        render_bundle(results.map { |r| { resourceType: "MedicationRequest" }.merge(r) })
      end

      def show
        render_not_found("MedicationRequest", params[:id])
      end
    end
  end
end
