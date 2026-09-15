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

      # `requires_new: true` is load-bearing, and the suite could not see it.
      #
      # A plain nested `transaction` JOINS its parent, and a join is not a
      # rollback boundary: an exception escaping it leaves the parent's writes
      # in place. Rails opens the transactional-test wrapper with
      # `joinable: false`, which silently promotes any inner `transaction` to
      # a savepoint — so the rollback "worked" in every test while failing for
      # the one caller that matters, a service or importer that owns its own
      # transaction around an audited write. Asking for the savepoint
      # explicitly makes the boundary real in both worlds.
      def audit_clinical_access
        @audit_recorded = false
        @audit_header_baseline = response.headers.to_h.keys.freeze
        publish_audit_context
        action_error = nil

        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            begin
              yield
            rescue StandardError => e
              action_error = e
              # Undo the action's writes; the attempt is recorded below, on
              # its own, so a failed action still leaves a trail.
              raise ActiveRecord::Rollback
            end

            record_audit_event!
            raise ActiveRecord::Rollback unless @audit_recorded
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
          tenant_identifier: audit_tenant_identifier,
          facility_identifier: audit_facility_identifier
        )
        @audit_recorded = true
      end

      # UNDER WHICH CONTEXT. Through the host's configured resolvers, so a
      # deployment that carries tenancy somewhere other than a header (a
      # subdomain, the token) is recorded correctly rather than blank.
      def audit_tenant_identifier
        Lakeraven::EHR.configuration.tenant_resolver&.call(request)
      rescue StandardError
        nil
      end

      def audit_facility_identifier
        Lakeraven::EHR.configuration.facility_resolver&.call(request)
      rescue StandardError
        nil
      end

      # Hand the acting identity down to code that never sees a request —
      # the RPMS broker most of all. A resolver, not a value: the actor is
      # established by the authentication before_action, which runs inside
      # this wrapper.
      def publish_audit_context
        AuditContext.agent_resolver = -> { audit_agent_attributes }
        AuditContext.network_address = request.remote_ip
        AuditContext.tenant_identifier = audit_tenant_identifier
        AuditContext.facility_identifier = audit_facility_identifier
        AuditContext.inside_audited_request = true
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
      # A surface that refused FOR A REASON is auditable whatever status it
      # ended up with: a redirect to a sign-in page is a refusal too, and an
      # attempt to read the audit log is exactly the attempt worth keeping.
      def auditable_access?
        audit_current_token || unauthenticated_audit_actor || refused_access? ||
          @audit_denial_reason.present? || resolved_clinician_duz.present?
      end

      # SmartAuthentication is not on every audited surface — the compliance
      # review screen authenticates against the browser session instead. Ask
      # rather than assume, so this concern wraps both kinds.
      def audit_current_token
        respond_to?(:current_token, true) ? current_token : nil
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
        elsif audit_current_token && !shared_browser_credential?
          { agent_who_type: "Application", agent_who_identifier: audit_current_token.application&.uid }
        else
          { agent_who_type: "Unknown", agent_who_identifier: nil }
        end
      end

      # A human, if one can be named. Two sources, most specific first:
      #
      #   * `current_duz` — the session-bridge work (#486). Not on this branch,
      #     hence `respond_to?`.
      #   * `session[:duz]` — the browser sign-on that exists TODAY. A browser
      #     surface already knows which human is signed in; filing that access
      #     under the OAuth application uid instead would make every clinician
      #     in the building look like the same actor.
      #
      # Neither is invented when absent: the row goes out unattributed.
      def resolved_clinician_duz
        return current_duz.presence if respond_to?(:current_duz, true) && current_duz.present?

        session_value(:duz)
      end

      def resolved_clinician_name
        return current_user_name if respond_to?(:current_user_name, true) && current_user_name.present?

        session_value(:user_name)
      end

      def session_value(key)
        return nil unless respond_to?(:session, true)

        session[key].presence
      rescue StandardError
        # No session middleware on this surface (an API controller).
        nil
      end

      def shared_browser_credential?
        return false unless respond_to?(:browser_sso_token?, true)

        audit_current_token && browser_sso_token?(audit_current_token)
      end

      # WHAT WAS DONE, from the HTTP verb. Everything used to be recorded as a
      # Read, so the log could not answer the question a records request
      # actually asks — what did this person CHANGE. A controller with a
      # finer-grained notion (an RPC that reads on POST) overrides this.
      AUDIT_ACTION_BY_METHOD = {
        "GET" => "R", "HEAD" => "R", "OPTIONS" => "R",
        "POST" => "C", "PUT" => "U", "PATCH" => "U", "DELETE" => "D"
      }.freeze

      def audit_action
        AUDIT_ACTION_BY_METHOD.fetch(request.request_method.to_s.upcase, "E")
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

      # Throw away EVERYTHING the action produced, then answer 503.
      #
      # A discarded body is not a discarded response. The same refusal has
      # three other ways to carry out the fact it is refusing:
      #
      #   * the headers — a Location naming the chart, an X-… the action set;
      #   * the flash — which a sibling PR carried out of a 503 in the session
      #     cookie, patient name and all;
      #   * `@_response_body`, which `render` reads to decide it is being
      #     called twice, so clearing `response_body` alone is not enough.
      #
      # Headers are cleared by DIFFERENCE against the set that existed before
      # the action ran, so anything the action added goes — including headers
      # nobody has thought of yet — and the 503 render supplies its own afresh.
      def deny_unrecorded_access
        self.response_body = nil
        @_response_body = nil
        discard_unrecorded_headers!
        discard_unrecorded_flash!
        render plain: "Service Unavailable: this access could not be recorded, so it was not completed",
               status: :service_unavailable
      end

      def discard_unrecorded_headers!
        baseline = @audit_header_baseline || []
        (response.headers.to_h.keys - baseline).each { |name| response.delete_header(name) }
      end

      # The flash outlives the response it was set on — that is its whole
      # point, and why it is the leak that survived a 503. `clear` empties it
      # and `discard` marks what remains as swept, so the session middleware
      # writes nothing.
      def discard_unrecorded_flash!
        # API controllers have no flash at all; only a browser surface does.
        return unless respond_to?(:flash, true)

        flash.clear
        flash.discard
      rescue StandardError => e
        Rails.logger.error("[audit] could not clear the flash on a refused access: #{e.message}")
      end
    end
  end
end
