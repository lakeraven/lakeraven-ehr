# frozen_string_literal: true

module Lakeraven
  module EHR
    class AuditEventsController < ApplicationController
      # Deliberately NO organization_scope declaration: the audit log spans
      # every organization (patient references, client ids, network metadata),
      # so org-bound backend credentials are denied it outright (fail closed).
      # Audit review is an administrative function, not a connector's.
      def index
        events = AuditEvent.recent.limit(100)
        render_bundle(events.map(&:to_fhir))
      end

      def show
        event = AuditEvent.find_by(id: params[:id])
        if event
          render_fhir(event.to_fhir)
        else
          render_not_found("AuditEvent", params[:id])
        end
      end
    end
  end
end
