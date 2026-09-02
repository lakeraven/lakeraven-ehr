# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationController < ActionController::API
      include SmartAuthentication
      include AuditableClinicalAccess

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_smart_token!
      before_action :authorize_fhir_scope!

      private

      def fhir_resource_type
        self.class.name.demodulize.delete_suffix("Controller").singularize
      end

      def authorize_fhir_scope!
        return if can_read?(fhir_resource_type)

        render_forbidden("Insufficient scope for reading #{fhir_resource_type}")
      end

      def authorize_fhir_write_scope!
        return if can_write?(fhir_resource_type)

        render_forbidden("Insufficient scope for writing #{fhir_resource_type}")
      end

      def render_operation_outcome(status:, severity:, code:, diagnostics: nil)
        outcome = {
          resourceType: "OperationOutcome",
          issue: [ { severity: severity, code: code, diagnostics: diagnostics }.compact ]
        }
        render json: outcome, status: status, content_type: FHIR_CONTENT_TYPE
      end

      def render_fhir(resource, status: :ok)
        render json: resource, status: status, content_type: FHIR_CONTENT_TYPE
      end

      def render_not_found(resource_type, id)
        render_operation_outcome(
          status: :not_found,
          severity: "error",
          code: "not-found",
          diagnostics: "#{resource_type}/#{id} not found"
        )
      end

      # Renders a searchset Bundle. Honours FHIR paging (Vardana §4 /
      # checklist item 7): `_count` caps the page size and `Bundle.link`
      # carries rel=self plus rel=next while more matches remain. The next
      # link is this same URL with `_page` advanced — FHIR treats paging
      # links as opaque, so the page parameter is server-defined.
      # `total` is always the FULL match count, not the page size.
      def render_bundle(entries, type: "searchset")
        total = entries.length
        page_entries, links = paginate_entries(entries)
        bundle = {
          resourceType: "Bundle",
          type: type,
          total: total,
          link: links,
          entry: page_entries.map { |e| { resource: e } }
        }
        render json: bundle, status: :ok, content_type: FHIR_CONTENT_TYPE
      end

      def paginate_entries(entries)
        links = [ { relation: "self", url: request.original_url } ]
        count = params[:_count].to_i
        return [ entries, links ] unless count.positive?

        page = [ params[:_page].to_i, 1 ].max
        offset = (page - 1) * count
        page_entries = entries.slice(offset, count) || []
        links << { relation: "next", url: url_for_page(page + 1) } if offset + count < entries.length
        [ page_entries, links ]
      end

      def url_for_page(page)
        uri = URI.parse(request.original_url)
        query = Rack::Utils.parse_query(uri.query.to_s).merge("_page" => page.to_s)
        uri.query = Rack::Utils.build_query(query)
        uri.to_s
      end
    end
  end
end
