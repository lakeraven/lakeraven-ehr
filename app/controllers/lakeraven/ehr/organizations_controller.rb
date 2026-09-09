# frozen_string_literal: true

module Lakeraven
  module EHR
    class OrganizationsController < ApplicationController
      # Reviewed decision (PR #460 security panel): directory/terminology
      # resources carry no per-patient PHI, and org-bound connectors need
      # them to interpret clinical references — so they stay readable to any
      # authenticated credential. Known residual: this lets an org-bound
      # credential enumerate the shared directory (tenant existence), which
      # is accepted for now and revisited if directories become per-tenant.
      organization_scope :not_patient_compartment, only: %i[show]
      def show
        org = Organization.find_by_ien(params[:ien])

        if org.nil?
          render_operation_outcome(status: :not_found, severity: "error", code: "not-found", diagnostics: "Organization not found")
          return
        end

        render_fhir(org.to_fhir)
      end
    end
  end
end
