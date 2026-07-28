# frozen_string_literal: true

module Lakeraven
  module EHR
    # After-action concern that logs every authenticated FHIR request
    # as an AuditEvent. Skips when no token is present (401 responses).
    #
    # PHI safety: the entity identifier (DFN/IEN/id) is hashed before
    # persistence; resource payloads, names, SSNs, and other PHI are never
    # written to the audit row. Backend identifier is captured for
    # cross-backend traceability without revealing patient identity.
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
          action: audit_action,
          outcome: audit_outcome,
          entity_type: fhir_resource_type,
          entity_identifier: sanitized_entity_identifier,
          backend_identifier: Lakeraven::EHR.configuration.backend.to_s,
          agent_who_type: "Application",
          agent_who_identifier: current_token.application&.uid,
          agent_network_address: request.remote_ip,
          tenant_identifier: request.headers["X-Tenant-Identifier"],
          facility_identifier: request.headers["X-Facility-Identifier"]
        )
      rescue => e
        Rails.logger.error(VistaRpc::PhiSanitizer.sanitize_message("AuditEvent write failed: #{e.message}"))
      end

      def audit_action
        case request.method_symbol
        when :get then "R"
        when :post then "C"
        when :put, :patch then "U"
        when :delete then "D"
        else "E"
        end
      end

      def audit_outcome
        case response.status
        when 200..299 then "0"   # success
        when 400..499 then "4"   # minor failure
        else "8"                 # serious failure
        end
      end

      def sanitized_entity_identifier
        identifier = params[:dfn] || params[:ien] || params[:id]
        VistaRpc::PhiSanitizer.hash_identifier(identifier)
      end
    end
  end
end
