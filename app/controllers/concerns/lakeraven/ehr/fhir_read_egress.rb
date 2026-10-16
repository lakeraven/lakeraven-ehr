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
    # the JSON chart and the HTML chart.
    module FHIRReadEgress
      extend ActiveSupport::Concern

      NDJSON_CONTENT_TYPE = "application/fhir+ndjson"
      private_constant :NDJSON_CONTENT_TYPE

      private

      def render_fhir_egress(payload, status: :ok)
        filtered = filter_fhir_for_egress(payload)
        return refuse_unfiltered_fhir_egress unless filtered

        render json: filtered, status: status, content_type: fhir_egress_content_type
      end

      # Same Bundle shape as ApplicationController#render_bundle.
      def render_bundle_egress(entries, type: "searchset")
        render_fhir_egress(fhir_search_bundle(entries, type: type))
      end

      def render_ndjson_egress(payload)
        filtered = egress_filter(payload)
        return refuse_unfiltered_ndjson_egress unless usable_ndjson_payload?(filtered)

        render plain: filtered, content_type: NDJSON_CONTENT_TYPE
      end

      # HTML chart renders this bundle; JSON callers go through render_fhir_egress.
      # Nil means the filter output is not a FHIR payload — callers must refuse.
      def filter_fhir_for_egress(payload)
        filtered = egress_filter(payload)
        filtered if usable_fhir_payload?(filtered)
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

      # A FHIR payload is a Hash whose resourceType is a String, whether the
      # key arrived as a string (JSON) or a symbol (in-process hashes).
      def usable_fhir_payload?(payload)
        return false unless payload.is_a?(Hash)

        fhir_resource_type_value(payload).is_a?(String)
      end

      def fhir_resource_type_value(payload)
        [ payload["resourceType"], payload[:resourceType] ].find { |value| value.is_a?(String) }
      end

      # "" is an empty file. Any other string must be NDJSON: every non-blank
      # line is a JSON object with a String resourceType.
      def usable_ndjson_payload?(payload)
        return false unless payload.is_a?(String)

        payload.each_line.all? { |line| usable_ndjson_line?(line) }
      end

      def usable_ndjson_line?(line)
        stripped = line.strip
        return true if stripped.empty?

        resource = JSON.parse(stripped)
        resource.is_a?(Hash) && resource["resourceType"].is_a?(String)
      rescue JSON::ParserError
        false
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
