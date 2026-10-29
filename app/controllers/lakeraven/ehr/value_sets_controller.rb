# frozen_string_literal: true

module Lakeraven
  module EHR
    class ValueSetsController < ApplicationController
      # Fixed on purpose: the sentence names neither the backend nor the adapter class.
      EXPAND_NOT_SUPPORTED_DIAGNOSTICS = "ValueSet expansion is not available on this server."

      def index
        service = TerminologyService.new
        valuesets = service.list_valuesets
        entries = valuesets.map { |vs| { resourceType: "ValueSet", id: vs["id"], name: vs["name"], title: vs["title"], status: vs["status"] || "active" } }
        render_bundle(entries)
      rescue TerminologyService::ValueSetNotFoundError, Terminology::AdapterNotAvailable, NotImplementedError
        render_bundle([])
      end

      def show
        service = TerminologyService.new
        valueset = service.get_valueset(params[:id])
        if valueset
          render_fhir({ resourceType: "ValueSet", id: valueset["id"], name: valueset["name"], title: valueset["title"], status: valueset["status"] || "active" })
        else
          render_valueset_not_found
        end
      rescue TerminologyService::ValueSetNotFoundError, Terminology::AdapterNotAvailable, NotImplementedError
        render_valueset_not_found
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
        render_valueset_not_found
      rescue Terminology::AdapterNotAvailable, NotImplementedError
        render_expansion_not_supported
      end

      private

      def render_valueset_not_found
        id = params[:id].to_s
        if Terminology::ValueSetId.safe?(id)
          render_not_found("ValueSet", id)
        else
          render_operation_outcome(status: :not_found, severity: "error", code: "not-found",
            diagnostics: "ValueSet not found")
        end
      end

      # $expand is not available on this backend. That is not-supported,
      # not a missing ValueSet (not-found). Same outcome shape as
      # FeatureUnavailableRendering. The diagnostics stay the fixed sentence.
      def render_expansion_not_supported
        render_operation_outcome(status: :not_found, severity: "error", code: "not-supported",
          diagnostics: EXPAND_NOT_SUPPORTED_DIAGNOSTICS)
      end
    end
  end
end
