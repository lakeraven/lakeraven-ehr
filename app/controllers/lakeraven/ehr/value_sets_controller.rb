# frozen_string_literal: true

module Lakeraven
  module EHR
    class ValueSetsController < ApplicationController
      # Fixed on purpose: the sentence names neither the backend nor the adapter class.
      # Index, show, and $expand all use it when the terminology backend has no adapter.
      TERMINOLOGY_NOT_SUPPORTED_DIAGNOSTICS = "ValueSet expansion is not available on this server."

      def index
        service = TerminologyService.new
        valuesets = service.list_valuesets
        entries = valuesets.map { |vs| { resourceType: "ValueSet", id: vs["id"], name: vs["name"], title: vs["title"], status: vs["status"] || "active" } }
        render_bundle(entries)
      rescue Terminology::AdapterNotAvailable => error
        refuse_unavailable_terminology(service, error)
      rescue TerminologyService::ValueSetNotFoundError, NotImplementedError
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
      rescue Terminology::AdapterNotAvailable => error
        refuse_unavailable_terminology(service, error)
      rescue TerminologyService::ValueSetNotFoundError, NotImplementedError
        render_valueset_not_found
      end

      def expand
        service = TerminologyService.new
        codes = service.expand_valueset(params[:id])
        render_fhir(valueset_expansion(params[:id], codes))
      rescue TerminologyService::ValueSetNotFoundError
        render_valueset_not_found
      rescue Terminology::AdapterNotAvailable => error
        refuse_unavailable_terminology(service, error)
      rescue NotImplementedError
        render_terminology_not_supported
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

      def valueset_expansion(id, codes)
        {
          resourceType: "ValueSet",
          id: id,
          expansion: {
            timestamp: Time.current.iso8601,
            total: codes.length,
            contains: codes.map { |c| { system: c[:system], code: c[:code], display: c[:display] } }
          }
        }
      end

      # One warning per request names the backend. ActiveSupport::Logger
      # writes only the message, so the severity word is in the text.
      # The OperationOutcome keeps the fixed diagnostics and names neither
      # the backend nor the adapter class. ValueSetNotFoundError stays
      # not-found on show and $expand. Index answers an empty Bundle for
      # ValueSetNotFoundError and NotImplementedError.
      def refuse_unavailable_terminology(service, error)
        backend = service&.backend || error.message
        Rails.logger.warn("WARN: ValueSet terminology backend #{backend} is unavailable")
        render_terminology_not_supported
      end

      # Same outcome shape as FeatureUnavailableRendering. The diagnostics
      # stay the fixed sentence for index, show, and $expand.
      def render_terminology_not_supported
        render_operation_outcome(status: :not_found, severity: "error", code: "not-supported",
          diagnostics: TERMINOLOGY_NOT_SUPPORTED_DIAGNOSTICS)
      end
    end
  end
end
