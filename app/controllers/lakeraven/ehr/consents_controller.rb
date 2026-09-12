# frozen_string_literal: true

module Lakeraven
  module EHR
    class ConsentsController < ApplicationController
      include PatientCompartment

      def index
        consents = Consent.for_patient(patient_compartment_dfn)
        render_bundle(consents.map(&:to_fhir))
      rescue => e
        render_bundle([])
      end

      def show
        render_not_found("Consent", params[:id])
      end
    end
  end
end
