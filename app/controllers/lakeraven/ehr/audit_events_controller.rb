# frozen_string_literal: true

module Lakeraven
  module EHR
    # GET /AuditEvent — compliance query endpoint.
    #
    # Returns a FHIR Bundle of AuditEvent resources scoped to the
    # current tenant. Supports filtering by entity (type + identifier)
    # via query parameters. Requires a system/AuditEvent.read or
    # user/AuditEvent.read scope on the Bearer token.
    class AuditEventsController < ApplicationController
      include SmartAuthentication

      before_action :authenticate_smart_token!
      before_action :require_audit_event_read_scope!, only: :index

      DEFAULT_PAGE_SIZE = 50
      MAX_PAGE_SIZE = 500

      def index
        return if require_complete_entity_filter!

        scope = AuditEvent.for_tenant(Current.tenant_identifier).recent
        scope = scope.for_entity(params["entity-type"], params["entity-identifier"]) if entity_filter_present?

        # Bundle.total reports the total matching row count across all
        # pages, not just the current page. Compute it before applying
        # the page limit so clients can use it for navigation and
        # compliance reporting.
        total_matches = scope.count

        limit = coerce_limit(params["_count"])
        events = scope.limit(limit).to_a

        render_fhir(build_bundle(events, total_matches))
      end

      private

      def require_audit_event_read_scope!
        authorize_resource_read!("AuditEvent")
      end

      # If only one of the entity-type / entity-identifier pair is
      # supplied, the request is ambiguous — fail loud with a 400
      # OperationOutcome rather than silently returning unfiltered
      # tenant rows.
      def require_complete_entity_filter!
        has_type = params["entity-type"].to_s.strip.present?
        has_id = params["entity-identifier"].to_s.strip.present?
        return false if has_type == has_id

        render_operation_outcome(
          status: :bad_request,
          severity: "error",
          code: "invalid",
          diagnostics: "entity-type and entity-identifier must be supplied together"
        )
        true
      end

      def entity_filter_present?
        params["entity-type"].to_s.strip.present? && params["entity-identifier"].to_s.strip.present?
      end

      def coerce_limit(value)
        n = value.to_i
        return DEFAULT_PAGE_SIZE if n <= 0
        [ n, MAX_PAGE_SIZE ].min
      end

      def build_bundle(events, total_matches)
        {
          resourceType: "Bundle",
          type: "searchset",
          total: total_matches,
          entry: events.map { |e|
            {
              resource: FHIR::AuditEventSerializer.call(e)
            }
          }
        }
      end
    end
  end
end
