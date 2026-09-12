# frozen_string_literal: true

module Lakeraven
  module EHR
    class ProceduresController < ApplicationController
      include PatientCompartment

      compartment_bound :index, param: :patient, require_param: true

      def index
        dfn = patient_compartment_dfn
        results = Procedure.for_patient(dfn)
        render_bundle(results.map { |r| { resourceType: "Procedure" }.merge(r) })
      end
    end
  end
end
