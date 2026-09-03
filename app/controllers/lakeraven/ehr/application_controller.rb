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
      # `_count=0` is the FHIR R4 summary-count form: the response carries
      # the total and ZERO entries (never the full set).
      # `total` is always the FULL match count, not the page size.
      #
      # Callers pass resources (wrapped as `{resource: ...}` entries), or
      # prebuilt entry hashes via `entries:` when they need `search.mode`
      # or _revinclude entries (Patient search) — every searchset goes
      # through this one path so paging behaves identically everywhere.
      def render_bundle(resources = [], type: "searchset", entries: nil, total: nil)
        entries ||= resources.map { |e| { resource: e } }
        page_entries, links = paginate_entries(entries)
        bundle = {
          resourceType: "Bundle",
          type: type,
          total: total || entries.length,
          link: links,
          entry: page_entries
        }
        render json: bundle, status: :ok, content_type: FHIR_CONTENT_TYPE
      end

      def paginate_entries(entries)
        links = [ { relation: "self", url: request.original_url } ]
        count = requested_count
        return [ entries, links ] if count.nil?
        return [ [], links ] if count.zero?

        page = [ params[:_page].to_i, 1 ].max
        offset = (page - 1) * count
        page_entries = entries.slice(offset, count) || []
        links << { relation: "next", url: url_for_page(page + 1) } if offset + count < entries.length
        [ page_entries, links ]
      end

      # `_count` parsed as a non-negative integer; absent or malformed →
      # nil (no paging). 0 is meaningful (summary count), so `.to_i` — which
      # can't distinguish "0" from garbage — is not used.
      def requested_count
        raw = params[:_count]
        return nil if raw.blank?

        count = Integer(raw.to_s, exception: false)
        count.nil? || count.negative? ? nil : count
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
