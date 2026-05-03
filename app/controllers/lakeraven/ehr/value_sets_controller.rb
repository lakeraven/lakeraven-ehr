# frozen_string_literal: true

module Lakeraven
  module EHR
    class ValueSetsController < ApplicationController
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
