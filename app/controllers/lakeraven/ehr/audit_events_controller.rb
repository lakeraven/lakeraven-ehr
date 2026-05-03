# frozen_string_literal: true

module Lakeraven
  module EHR
    class AuditEventsController < ApplicationController
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
