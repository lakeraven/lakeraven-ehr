# frozen_string_literal: true

module Lakeraven
  module EHR
    # One seam for disclosing FHIR reads and bulk-export file bytes.
    #
    # Callers hand over the payload they would have rendered. The response
    # body is what Part2EgressFilter returns. Nil, or a value that cannot
    # be sent as that response type, is a 503 with no clinical content —
    # the same fail-closed posture TransitionsOfCareController uses when
    # the filter does not return C-CDA sections.
    #
    # Directory, terminology, and status endpoints keep render_fhir /
    # render_bundle and do not enter this seam. ChartsController does not
    # inherit the FHIR base controller, so it includes this concern for
    # the JSON chart only.
    module FHIRReadEgress
      extend ActiveSupport::Concern

      NDJSON_CONTENT_TYPE = "application/fhir+ndjson"
      private_constant :NDJSON_CONTENT_TYPE

      private

      def render_fhir_egress(payload, status: :ok)
        filtered = egress_filter(payload)
        return refuse_unfiltered_fhir_egress unless filtered.is_a?(Hash)

        render json: filtered, status: status, content_type: fhir_egress_content_type
      end

      # Same Bundle shape as ApplicationController#render_bundle.
      def render_bundle_egress(entries, type: "searchset")
        render_fhir_egress(fhir_search_bundle(entries, type: type))
      end

      def render_ndjson_egress(payload)
        filtered = egress_filter(payload)
        return refuse_unfiltered_ndjson_egress unless filtered.is_a?(String)

        render plain: filtered, content_type: NDJSON_CONTENT_TYPE
      end

      def fhir_search_bundle(entries, type: "searchset")
        {
          resourceType: "Bundle",
          type: type,
          total: entries.length,
          entry: entries.map { |entry| { resource: entry } }
        }
      end

      def egress_filter(payload)
        Part2EgressFilter.call(payload)
      end

      def fhir_egress_content_type
        self.class::FHIR_CONTENT_TYPE
      end

      def refuse_unfiltered_fhir_egress
        diagnostics = "Part 2 egress filter did not return a FHIR payload"
        if respond_to?(:render_operation_outcome, true)
          render_operation_outcome(
            status: :service_unavailable,
            severity: "error",
            code: "exception",
            diagnostics: diagnostics
          )
        else
          render_fhir_egress_refusal(diagnostics)
        end
      end

      # ChartsController has no render_operation_outcome of its own.
      def render_fhir_egress_refusal(diagnostics)
        render json: {
          resourceType: "OperationOutcome",
          issue: [ { severity: "error", code: "exception", diagnostics: diagnostics } ]
        }, status: :service_unavailable, content_type: fhir_egress_content_type
        note_audit_denial("fhir operation refused: exception (HTTP #{response.status})")
      end

      def refuse_unfiltered_ndjson_egress
        # An OperationOutcome is itself a FHIR resource. The file refusal
        # is a body with no resource content.
        render plain: "Part 2 egress filter did not return an export file",
               status: :service_unavailable, content_type: "text/plain"
        note_audit_denial("fhir operation refused: exception (HTTP #{response.status})")
      end
    end
  end
end
