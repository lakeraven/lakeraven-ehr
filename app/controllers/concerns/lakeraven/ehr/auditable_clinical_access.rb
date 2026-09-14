# frozen_string_literal: true

module Lakeraven
  module EHR
    # Clinical audit that FAILS CLOSED. If it can't be written down, it didn't
    # happen.
    #
    # This concern used to record with an `after_action`, best effort. Two ways
    # that lost the events most worth keeping:
    #
    #   * Rails skips after-callbacks when a before-callback HALTS the chain,
    #     so every refusal was invisible — 200 wrote a row, 403 and 401 wrote
    #     nothing. A clinician probing charts outside their own compartment
    #     left no trace at all, which is the §164.312(b) question exactly.
    #     Tightening authorization without fixing this makes the audit log
    #     quieter, not safer.
    #   * A failed insert was logged and the response — the PHI — went out
    #     anyway.
    #
    # So the audit happens AROUND the action, and the audit row is written in
    # the SAME transaction as whatever the action wrote. An audited write and
    # its audit row commit together or not at all. Recording after `yield`
    # without a transaction is not enough: the action's writes have already
    # committed by then, so a failed audit leaves a change nothing can account
    # for. (That was the defect round 4 found in this pattern's first version.)
    #
    # When the access cannot be recorded, it is not completed: the response is
    # thrown away and replaced with 503, and the controller gets a chance to
    # undo non-database state through `rollback_unrecorded_access`.
    module AuditableClinicalAccess
      extend ActiveSupport::Concern

      included do
        # Registered at include time, which is before each controller declares
        # its own before_actions — so this wraps them, and a halted chain is
        # still audited.
        around_action :audit_clinical_access
      end

      private

      def audit_clinical_access
        @audit_recorded = false
        action_error = nil

        begin
          ActiveRecord::Base.transaction do
            begin
              yield
            rescue StandardError => e
              action_error = e
              # Undo the action's writes; the attempt is recorded below, on
              # its own, so a failed action still leaves a trail.
              raise ActiveRecord::Rollback
            end

            record_audit_event!
          end
        rescue StandardError => e
          # The audit insert itself failed, taking the action's writes with it.
          Rails.logger.error("[audit] refusing to serve an unrecorded clinical access: #{e.message}")
        end
        # The action raised, so its transaction rolled back — including any
        # audit row written inside it. Record the attempt in its own.
        record_attempt_after_rollback if action_error

        unless @audit_recorded
          rollback_unrecorded_access
          return deny_unrecorded_access
        end

        raise action_error if action_error
      end

      # Best-effort form, kept for callers that record outside the around
      # wrapper. Prefer the wrapper: this one serves the request either way.
      def record_audit_event
        record_audit_event!
      rescue => e
        Rails.logger.error("AuditEvent write failed: #{e.message}")
      end

      # Raises if the access could not be recorded.
      #
      # At most ONE row per request: the guard makes a double registration of
      # this concern (a controller that also mixes in a fail-closed variant)
      # record once rather than twice.
      def record_audit_event!
        return if @audit_recorded
        return unless auditable_access?

        AuditEvent.create!(
          event_type: "rest",
          action: audit_action,
          outcome: audit_outcome,
          outcome_desc: @audit_denial_reason,
          entity_type: fhir_resource_type,
          entity_identifier: audit_entity_identifier,
          **audit_agent_attributes,
          agent_network_address: request.remote_ip,
          tenant_identifier: request.headers["X-Tenant-Identifier"],
          facility_identifier: request.headers["X-Facility-Identifier"]
        )
        @audit_recorded = true
      end

      def record_attempt_after_rollback
        record_audit_event!
      rescue StandardError => e
        Rails.logger.error("[audit] could not record a failed access: #{e.message}")
      end

      # WHAT is worth a row.
      #
      # A rejected credential carries no identity, but it is exactly the event
      # worth recording — so a refusal is auditable even with no token at all.
      def auditable_access?
        current_token || unauthenticated_audit_actor || refused_access?
      end

      def refused_access?
        response.status >= 400
      end

      # Record WHY a request was refused. A denial that does not say what it
      # denied is not much of a record — "we could not determine" and "we
      # determined no" have to be distinguishable afterwards.
      def note_audit_denial(reason)
        @audit_denial_reason = reason
      end

      # Tokenless requests are unaudited by default unless refused. A
      # controller with a deliberate unauthenticated path (the chart's
      # dev-only demo bypass) overrides this to return a service actor name
      # (e.g. "demo-bypass") so those requests still leave an audit trail.
      # Must return a fixed, non-request-derived identifier — never user
      # input or PHI.
      def unauthenticated_audit_actor
        nil
      end

      # WHO. An UNATTRIBUTED row is worth more than a misattributed one.
      #
      # `current_duz` and `browser_sso_token?` belong to the session-bridge
      # work (#486) and are NOT on this branch, so both are behind
      # `respond_to?`. Until that lands there is no browser application here
      # and every token is a system client, which the application uid names
      # accurately. Afterwards, a browser token whose clinician cannot be
      # resolved must NOT be filed under the shared browser application — every
      # clinician would look identical, which is the defect #486 fixes. It is
      # recorded as unattributed instead.
      def audit_agent_attributes
        duz = resolved_clinician_duz
        if duz.present?
          return { agent_who_type: "Practitioner", agent_who_identifier: duz,
                   agent_name: resolved_clinician_name }
        end

        if unauthenticated_audit_actor
          { agent_who_type: "Service", agent_who_identifier: unauthenticated_audit_actor }
        elsif current_token && !shared_browser_credential?
          { agent_who_type: "Application", agent_who_identifier: current_token.application&.uid }
        else
          { agent_who_type: "Unknown", agent_who_identifier: nil }
        end
      end

      def resolved_clinician_duz
        return nil unless respond_to?(:current_duz, true)

        current_duz.presence
      end

      def resolved_clinician_name
        return nil unless respond_to?(:current_user_name, true)

        current_user_name
      end

      def shared_browser_credential?
        return false unless respond_to?(:browser_sso_token?, true)

        current_token && browser_sso_token?(current_token)
      end

      # FHIR reads are the common case; a controller that also writes
      # overrides this per action so a creation is not logged as a read.
      def audit_action
        "R"
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

      # An action that established non-database state undoes it here: state
      # the audit log has no record of must not survive the request.
      def rollback_unrecorded_access; end

      # Throw away whatever the action produced — a rendered page, a redirect —
      # and answer 503. `response_body = nil` resets the response but leaves
      # ActionController::Metal's own `@_response_body` set, which `render`
      # reads to decide it is being called twice; and a discarded redirect
      # would otherwise leave its Location header behind.
      def deny_unrecorded_access
        self.response_body = nil
        @_response_body = nil
        response.delete_header("Location")
        render plain: "Service Unavailable: this access could not be recorded, so it was not completed",
               status: :service_unavailable
      end
    end
  end
end
