# frozen_string_literal: true

module Lakeraven
  module EHR
    class ValueSetsController < ApplicationController
      # Reviewed decision (PR #460 security panel): directory/terminology
      # resources carry no per-patient PHI, and org-bound connectors need
      # them to interpret clinical references — so they stay readable to any
      # authenticated credential. Known residual: this lets an org-bound
      # credential enumerate the shared directory (tenant existence), which
      # is accepted for now and revisited if directories become per-tenant.
      organization_scope :not_patient_compartment, only: %i[index show expand]
      def index
        service = TerminologyService.new
        valuesets = service.list_valuesets
        entries = valuesets.map { |vs| { resourceType: "ValueSet", id: vs["id"], name: vs["name"], title: vs["title"], status: vs["status"] || "active" } }
        render_bundle(entries)
      rescue TerminologyService::ValueSetNotFoundError, NotImplementedError
        render_bundle([])
      end

      def show
        service = TerminologyService.new
        valueset = service.get_valueset(params[:id])
        if valueset
          render_fhir({ resourceType: "ValueSet", id: valueset["id"], name: valueset["name"], title: valueset["title"], status: valueset["status"] || "active" })
        else
          render_not_found("ValueSet", params[:id])
        end
      rescue TerminologyService::ValueSetNotFoundError, NotImplementedError
        render_not_found("ValueSet", params[:id])
      end

      def expand
        service = TerminologyService.new
        codes = service.expand_valueset(params[:id])
        expansion = {
          resourceType: "ValueSet",
          id: params[:id],
          expansion: {
            timestamp: Time.current.iso8601,
            total: codes.length,
            contains: codes.map { |c| { system: c[:system], code: c[:code], display: c[:display] } }
          }
        }
        render_fhir(expansion)
      rescue TerminologyService::ValueSetNotFoundError
        render_not_found("ValueSet", params[:id])
      end
    end
  end
end
