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
    # An export file's check depends on its type. fhir_ndjson keeps the
    # NDJSON-of-resources rule ("" is an empty file; a resourceType must
    # be a non-empty String). audit_csv is a String whose first line is
    # EhiExportService's header row. configuration and manifest are a
    # String that parses to a JSON object. Any other type is refused.
    # That refusal is an empty 503.
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

      # Same Bundle shape as ApplicationController#render_bundle: one page of
      # the matches, built by FHIRSearchBundle.
      def render_bundle_egress(entries, type: "searchset")
        render_fhir_egress(fhir_search_bundle(entries, type: type))
      end

      def render_export_file_egress(file)
        filtered = egress_filter(file["content"])
        kind = export_file_kind(file)
        return refuse_unfiltered_export_file unless usable_export_file?(kind, filtered)

        render plain: filtered, content_type: export_file_content_type(kind)
      end

      # HTML chart renders this bundle; JSON callers go through render_fhir_egress.
      # Nil means the filter output is not a FHIR payload — callers must refuse.
      def filter_fhir_for_egress(payload)
        filtered = egress_filter(payload)
        filtered if usable_fhir_payload?(filtered)
      end

      def egress_filter(payload)
        Part2EgressFilter.call(payload)
      end

      # A FHIR payload is a Hash whose resourceType is a non-empty String,
      # whether the key arrived as a string (JSON) or a symbol (in-process hashes).
      def usable_fhir_payload?(payload)
        return false unless payload.is_a?(Hash)

        type = fhir_resource_type_value(payload)
        type.is_a?(String) && !type.empty?
      end

      def fhir_resource_type_value(payload)
        [ payload["resourceType"], payload[:resourceType] ].find { |value| value.is_a?(String) }
      end

      # `file_type` is what EhiExportService set. The manifest `type` is
      # the FHIR resource name for an NDJSON file (Patient, …), including
      # a file stored with no file_type.
      def export_file_kind(file)
        case resolved_export_file_type(file)
        when "fhir_ndjson" then :fhir_ndjson
        when "audit_csv" then :audit_csv
        when "configuration", "manifest" then :json
        else :unknown
        end
      end

      def resolved_export_file_type(file)
        type = file["file_type"].presence || file["type"].to_s
        return "fhir_ndjson" if fhir_ndjson_type?(type)

        type
      end

      def fhir_ndjson_type?(type)
        type == "fhir_ndjson" || BulkExport::SUPPORTED_RESOURCES.include?(type)
      end

      def usable_export_file?(kind, payload)
        case kind
        when :fhir_ndjson then usable_ndjson_payload?(payload)
        when :audit_csv then usable_audit_csv?(payload)
        when :json then usable_json_payload?(payload)
        else false
        end
      end

      def export_file_content_type(kind)
        case kind
        when :fhir_ndjson then NDJSON_CONTENT_TYPE
        when :audit_csv then "text/csv"
        when :json then "application/json"
        end
      end

      # "" is an empty file. Any other string must be NDJSON: every non-blank
      # line is a JSON object with a non-empty String resourceType.
      def usable_ndjson_payload?(payload)
        return false unless payload.is_a?(String)

        payload.each_line.all? { |line| usable_ndjson_line?(line) }
      end

      def usable_ndjson_line?(line)
        stripped = line.strip
        return true if stripped.empty?

        resource = JSON.parse(stripped)
        type = resource["resourceType"] if resource.is_a?(Hash)
        type.is_a?(String) && !type.empty?
      rescue JSON::ParserError
        false
      end

      # The first line is the header row EhiExportService writes. Any other
      # text is not an audit file, even when it is a String.
      def usable_audit_csv?(payload)
        return false unless payload.is_a?(String)

        payload.lines.first.to_s.chomp == EhiExportService.audit_csv_header_line
      end

      def usable_json_payload?(payload)
        return false unless payload.is_a?(String)

        JSON.parse(payload).is_a?(Hash)
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

      # An OperationOutcome is itself a FHIR resource. An export-file
      # refusal is a 503 with an empty body.
      def refuse_unfiltered_export_file
        render plain: "", status: :service_unavailable, content_type: "text/plain"
        note_audit_denial("fhir operation refused: exception (HTTP #{response.status})")
      end
    end
  end
end
