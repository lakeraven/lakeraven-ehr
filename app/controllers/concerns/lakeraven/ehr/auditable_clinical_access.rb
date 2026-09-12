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

      # AROUND, not after. Rails skips after-callbacks when a before-callback
      # halts the chain — so every refusal was invisible: 200 wrote a row,
      # 403 and 401 wrote nothing. This PR CREATES most of those 403 paths
      # (compartment binding, verb-aware scope, deny-by-default scopes), so
      # tightening authorization without this would have made the audit log
      # quieter, not safer: a clinician probing charts outside their own
      # compartment left no trace at all.
      #
      # Registered at include time, which is before each controller declares
      # its own before_actions, so this wraps them.
      included do
        around_action :audit_clinical_access
      end

      private

      def audit_clinical_access
        yield
      ensure
        record_audit_event
      end

      # Record WHY a request was refused, for the audit trail. Called from the
      # refusal renderers; a denial that does not say what it denied is not
      # much of a record.
      def note_audit_denial(reason)
        @audit_denial_reason = reason
      end

      def record_audit_event
        # A rejected credential has no token, but it is exactly the event worth
        # recording. Audit it as an unidentified actor rather than not at all.
        return if current_token.nil? && unauthenticated_audit_actor.nil? && !audit_refusal?

        AuditEvent.create!(
          event_type: "rest",
          action: "R",
          outcome: audit_outcome,
          entity_type: fhir_resource_type,
          entity_identifier: audit_entity_identifier,
          **audit_agent_attributes,
          outcome_desc: @audit_denial_reason,
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

      # WHO opened this chart.
      #
      # Every browser session shares ONE Doorkeeper application, so recording
      # `application.uid` made two different clinicians reading the same record
      # byte-identical in the audit log — and "which staff member opened this
      # behavioral-health record" unanswerable, which is the first question
      # asked after a Part 2 incident (§170.315(d)(2)/(d)(3), §164.312(b)).
      #
      # A session-derived token carries the clinician's DUZ, so it is recorded
      # as a Practitioner agent. Header/system tokens have no human behind
      # them and keep the application identity they already had.
      def audit_refusal?
        response.status >= 400
      end

      def audit_agent_attributes
        duz = (current_duz if respond_to?(:current_duz, true))

        if duz.present?
          { agent_who_type: "Practitioner", agent_who_identifier: duz,
            agent_name: (current_user_name if respond_to?(:current_user_name, true)) }
        elsif current_token
          { agent_who_type: "Application", agent_who_identifier: current_token.application&.uid }
        elsif unauthenticated_audit_actor
          { agent_who_type: "Service", agent_who_identifier: unauthenticated_audit_actor }
        else
          # A refused credential names nobody. Record the attempt anyway — the
          # network address is on the row regardless.
          { agent_who_type: "Unknown", agent_who_identifier: "unauthenticated" }
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
