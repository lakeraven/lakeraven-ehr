# frozen_string_literal: true

module Lakeraven
  module EHR
    class ConditionsController < ApplicationController
      include PatientCompartment

      compartment_bound :index, param: :patient, require_param: true

      def index
        dfn = patient_compartment_dfn
        results = Condition.for_patient(dfn)
        render_bundle(results.map { |r| Condition.from_rpms_row(r, patient_dfn: dfn).to_fhir })
      end

      def show
        render_not_found("Condition", params[:id])
      end
    end
  end
end
