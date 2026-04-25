# frozen_string_literal: true

module Lakeraven
  module EHR
    # After-action concern that logs every authenticated FHIR request
    # as an AuditEvent. Skips when no token is present (401 responses).
    module AuditableClinicalAccess
      extend ActiveSupport::Concern

      included do
        after_action :record_audit_event
      end

      private

      def record_audit_event
        return unless current_token

        AuditEvent.create!(
          event_type: "rest",
          action: "R",
          outcome: audit_outcome,
          entity_type: fhir_resource_type,
          entity_identifier: audit_entity_identifier,
          agent_who_type: "Application",
          agent_who_identifier: current_token.application&.uid,
          agent_network_address: request.remote_ip,
          tenant_identifier: request.headers["X-Tenant-Identifier"],
          facility_identifier: request.headers["X-Facility-Identifier"]
        )
      rescue => e
        Rails.logger.error("AuditEvent write failed: #{e.message}")
      end

      def audit_outcome
        case response.status
        when 200..299 then "0"   # success
        when 400..499 then "4"   # minor failure
        else "8"                 # serious failure
        end
      end

      def audit_entity_identifier
        params[:dfn] || params[:ien] || params[:id]
      end
    end
  end
end
