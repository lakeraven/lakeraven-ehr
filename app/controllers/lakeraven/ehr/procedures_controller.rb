# frozen_string_literal: true

module Lakeraven
  module EHR
    class ProceduresController < ApplicationController
      include PatientCompartment

      compartment_bound :index, param: :patient, require_param: true

      def index
        dfn = patient_compartment_dfn
        results = Procedure.for_patient(dfn)
        render_bundle_egress(results.map { |r| Procedure.from_rpms_row(r, patient_dfn: dfn).to_fhir })
      end
    end
  end
end
