# frozen_string_literal: true

module Lakeraven
  module EHR
    class PractitionersController < ApplicationController
      # Reviewed decision (PR #460 security panel): directory/terminology
      # resources carry no per-patient PHI, and org-bound connectors need
      # them to interpret clinical references — so they stay readable to any
      # authenticated credential. Known residual: this lets an org-bound
      # credential enumerate the shared directory (tenant existence), which
      # is accepted for now and revisited if directories become per-tenant.
      organization_scope :not_patient_compartment, only: %i[index show]
      def index
        practitioners = if params[:name].present?
                          Practitioner.search(params[:name])
        else
                          Practitioner.search("")
        end

        render_bundle(practitioners.map(&:to_fhir))
      end

      def show
        practitioner = Practitioner.find_by_ien(params[:ien])

        if practitioner.nil?
          render_operation_outcome(
            status: :not_found,
            severity: "error",
            code: "not-found",
            diagnostics: "Practitioner not found"
          )
          return
        end

        render_fhir(practitioner.to_fhir)
      end
    end
  end
end
