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
        scope = AuditEvent.for_tenant(Current.tenant_identifier).recent
        scope = scope.for_entity(params["entity-type"], params["entity-identifier"]) if params["entity-type"] && params["entity-identifier"]

        limit = coerce_limit(params["_count"])
        events = scope.limit(limit).to_a

        render_fhir(build_bundle(events, limit))
      end

      private

      def require_audit_event_read_scope!
        authorize_resource_read!("AuditEvent")
      end

      def coerce_limit(value)
        n = value.to_i
        return DEFAULT_PAGE_SIZE if n <= 0
        [ n, MAX_PAGE_SIZE ].min
      end

      def build_bundle(events, limit)
        {
          resourceType: "Bundle",
          type: "searchset",
          total: events.length,
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
