# frozen_string_literal: true

module Lakeraven
  module EHR
    class ApplicationController < ActionController::API
      include SmartAuthentication
      include AuditableClinicalAccess

      FHIR_CONTENT_TYPE = "application/fhir+json"

      before_action :authenticate_smart_token!
      before_action :authorize_fhir_scope!
      # Org-bound backend credentials cannot reach another organization's
      # patients. Enforcement binds to the RESOLVED patient / result set per
      # each controller's `organization_scope` declaration, and any action
      # WITHOUT a declaration is denied to org-bound credentials (fail
      # closed) — see SmartAuthentication.
      before_action :enforce_organization_scope!
      # Patient-context (SMART patient/-scoped) tokens are confined to their
      # bound patient's compartment. Any action searching by ?patient= is
      # checked here centrally, so no per-patient search endpoint can leak
      # another patient's records to a patient-bound token by omission
      # (authorize_patient_context! is a no-op for system/user tokens).
      # Resource reads (#show) re-check against the RESOLVED resource's
      # owner in each controller.
      before_action :enforce_patient_compartment_on_search!

      private

      def enforce_patient_compartment_on_search!
        return true if params[:patient].blank?

        authorize_patient_context!(params[:patient].to_s.delete_prefix("Patient/"))
      end

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

      # Renders a searchset Bundle of FHIR resource hashes.
      #
      # Pagination (Vardana source-system profile section 4): when the
      # client sends `_count`, the match set is sliced into pages addressed
      # by `_page`, `Bundle.total` stays the FULL match count, and a
      # `Bundle.link` with relation "next" is emitted while more matches
      # remain. Without `_count` the whole set is returned in one page.
      #
      # `includes` carries _include/_revinclude resources (search.mode
      # "include"); per FHIR they ride along with every page and never count
      # toward `total` or the page size.
      def render_bundle(entries, type: "searchset", includes: [])
        page_entries, links = paginate_entries(entries)
        bundle = {
          resourceType: "Bundle",
          type: type,
          total: entries.length,
          link: links,
          entry: page_entries.map { |e| { resource: e, search: { mode: "match" } } } +
                 includes.map { |e| { resource: e, search: { mode: "include" } } }
        }
        render json: bundle, status: :ok, content_type: FHIR_CONTENT_TYPE
      end

      def paginate_entries(entries)
        count = params[:_count].to_i
        links = [ { relation: "self", url: request.original_url } ]
        return [ entries, links ] unless count.positive?

        page = [ params[:_page].to_i, 1 ].max
        offset = (page - 1) * count
        if offset + count < entries.length
          links << { relation: "next", url: page_url(page + 1, count) }
        end
        [ entries.slice(offset, count) || [], links ]
      end

      def page_url(page, count)
        uri = URI.parse(request.original_url)
        query = Rack::Utils.parse_query(uri.query.to_s)
        query["_page"] = page.to_s
        query["_count"] = count.to_s
        uri.query = Rack::Utils.build_query(query)
        uri.to_s
      end
    end
  end
end
