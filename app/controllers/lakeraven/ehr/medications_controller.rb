# frozen_string_literal: true

module Lakeraven
  module EHR
    class MedicationsController < ApplicationController
      # Medication is a definitional/directory resource with no per-patient
      # PHI (same reviewed posture as Practitioner, PR #460): readable by any
      # authenticated credential so connectors can resolve what a
      # MedicationRequest prescribes.
      organization_scope :not_patient_compartment, only: %i[index show]

      def index
        medications = MedicationStore.instance.all
        if params[:code].present?
          codes = params[:code].split(",")
          medications = medications.select { |m| codes.include?(m.code) }
        end
        render_bundle(medications.map(&:to_fhir))
      end

      def show
        medication = MedicationStore.instance.find(params[:id])
        return render_not_found("Medication", params[:id]) unless medication

        render_fhir(medication.to_fhir)
      end
    end
  end
end
