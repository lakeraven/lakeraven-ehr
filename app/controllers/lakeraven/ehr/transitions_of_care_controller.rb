# frozen_string_literal: true

module Lakeraven
  module EHR
    # ONC §170.315(b)(1) — Transitions of Care (send path)
    # Generates C-CDA documents for patient care transitions.
    class TransitionsOfCareController < ApplicationController
      # POST /transitions_of_care
      def create
        patient = Patient.find_by_dfn(params[:patient_dfn])
        unless patient
          return render_not_found("Patient", params[:patient_dfn])
        end

        allergies = AllergyIntolerance.for_patient(params[:patient_dfn]) rescue []
        conditions = Condition.for_patient(params[:patient_dfn]) rescue []
        medications = MedicationRequest.for_patient(params[:patient_dfn]) rescue []

        ccda_xml = CcdaGenerator.generate(
          patient: patient,
          allergies: allergies,
          conditions: conditions,
          medications: medications,
          author: {name: params[:author_name], npi: params[:author_npi]}
        )

        render xml: ccda_xml, status: :created, content_type: "application/xml"
      end
    end
  end
end
