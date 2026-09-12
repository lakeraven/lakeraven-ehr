# frozen_string_literal: true

module Lakeraven
  module EHR
    class ConditionsController < ApplicationController
      include PatientCompartment

      def index
        dfn = patient_compartment_dfn
        results = Condition.for_patient(dfn)
        render_bundle(results.map { |r| { resourceType: "Condition" }.merge(r) })
      end

      def show
        render_not_found("Condition", params[:id])
      end
    end
  end
end
