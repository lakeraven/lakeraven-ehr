# frozen_string_literal: true

module Lakeraven
  module EHR
    # After-action concern that logs every authenticated FHIR request
    # as an AuditEvent. Skips when no token is present (401 responses) —
    # UNLESS the controller declares an unauthenticated audit actor (e.g. the
    # chart's dev-only demo bypass), in which case the access is still audited
    # under that dedicated actor identity so bypass requests are never
    # invisible to the audit log (independent security review finding).
    module AuditableClinicalAccess
      extend ActiveSupport::Concern

      included do
        after_action :record_audit_event
      end

      private

      def record_audit_event
        return unless current_token || unauthenticated_audit_actor

        AuditEvent.create!(
          event_type: "rest",
          action: "R",
          outcome: audit_outcome,
          entity_type: fhir_resource_type,
          entity_identifier: audit_entity_identifier,
          **audit_agent_attributes,
          agent_network_address: request.remote_ip,
          tenant_identifier: request.headers["X-Tenant-Identifier"],
          facility_identifier: request.headers["X-Facility-Identifier"]
        )
      rescue => e
        Rails.logger.error("AuditEvent write failed: #{e.message}")
      end

      # Tokenless requests are unaudited by default (they are 401s). A
      # controller with a deliberate unauthenticated path (the chart's
      # dev-only demo bypass) overrides this to return a service actor name
      # (e.g. "demo-bypass") so those requests still leave an audit trail.
      # Must return a fixed, non-request-derived identifier — never user
      # input or PHI.
      def unauthenticated_audit_actor
        nil
      end

      def audit_agent_attributes
        if current_token
          { agent_who_type: "Application", agent_who_identifier: current_token.application&.uid }
        else
          { agent_who_type: "Service", agent_who_identifier: unauthenticated_audit_actor }
        end
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
