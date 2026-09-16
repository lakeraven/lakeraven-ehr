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
    # thrown away and replaced with 503, session and cookie-jar writes are
    # rolled back to their pre-action state, and the controller gets a chance
    # to undo anything else through `rollback_unrecorded_access`.
    module AuditableClinicalAccess
      extend ActiveSupport::Concern

      included do
        # PREPENDED, not merely registered early (F4, round-2 gate on #512):
        # include-time registration beats every before_action the controller
        # declares later, but Rails installed `verify_authenticity_token` on
        # ActionController::Base long before this concern arrived — so a
        # plain `around_action` ran INSIDE it, and a CSRF-refused cross-site
        # POST halted unrecorded on every browser surface. Prepending puts
        # the wrapper outside the whole chain; the CSRF exception is then
        # recorded as a determined refusal (see `csrf_refusal?`). The
        # ordering is pinned by a guard test.
        prepend_around_action :audit_clinical_access
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
        @audit_anomalies = []
        @audit_header_baseline = capture_header_baseline
        @audit_session_baseline = capture_session_baseline
        publish_audit_context
        action_error = nil

        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            begin
              yield
            rescue StandardError => e
              action_error = e
              # A CSRF rejection is "we determined no", with a reason — not
              # an anonymous serious failure (F4).
              note_audit_denial("cross-site request refused: #{e.class.name}") if csrf_refusal?(e)
              # Undo the action's writes; the attempt is recorded below, on
              # its own, so a failed action still leaves a trail.
              raise ActiveRecord::Rollback
            end

            record_audit_event!
            raise ActiveRecord::Rollback unless audit_settled?
          end
        rescue StandardError => e
          # The audit insert failed — or the TRANSACTION failed while
          # committing AFTER the insert succeeded and set the recorded flag
          # (lost connection, deferred constraint). Either way the row did
          # not survive, so the flag must not either: a stale true here would
          # serve a response whose audit row rolled back (review finding on
          # #512).
          @audit_recorded = false
          Rails.logger.error("[audit] refusing to serve an unrecorded clinical access: #{e.message}")
        end
        # The action raised, so its transaction rolled back — including any
        # audit row written inside it. Record the attempt in its own,
        # AS THE FAILURE IT WAS: `response.status` is still 200 at this point
        # (the exception has not become a response yet), so reading the status
        # here would file a raising access as a success — the S4 defect.
        if action_error
          @audit_action_failure = action_error
          record_attempt_after_rollback
        end

        unless audit_settled?
          rollback_unrecorded_access
          return deny_unrecorded_access
        end

        raise action_error if action_error
      end

      # "Recorded" and "needed no record" are both settled; only "should have
      # been recorded and could not be" is a refusal.
      #
      # The distinction exists because this concern is mixed into whole
      # controller bases, and a browser base serves pages that touch no
      # patient data at all — the sign-in form most of all. Treating those as
      # unrecordable would answer 503 to the login page. Every surface that
      # touches PHI arrives here either holding a credential, declaring a
      # service actor, or refusing — all three of which are auditable — so
      # this widens what needs no row, never what may go unrecorded.
      def audit_settled?
        @audit_recorded || !auditable_access?
      end

      # Raises if the access could not be recorded.
      #
      # At most ONE row per request: the guard makes a double registration of
      # this concern (a controller that also mixes in a fail-closed variant)
      # record once rather than twice.
      def record_audit_event!(detached: false)
        return if @audit_recorded
        return unless auditable_access?

        # Everything that can NOTE AN ANOMALY resolves BEFORE outcome_desc,
        # or the description would miss it: attribution, the entity pair,
        # and the bounded tenant/facility values.
        agent = audit_agent_attributes
        entity_type_value, entity_identifier_value = audit_entity_reference
        tenant = audit_tenant_identifier
        facility = audit_facility_identifier

        persist_audit_row!(
          detached: detached,
          event_type: "rest",
          action: audit_action,
          outcome: audit_outcome,
          outcome_desc: audit_outcome_desc,
          entity_type: entity_type_value,
          entity_identifier: entity_identifier_value,
          **agent,
          agent_network_address: request.remote_ip,
          tenant_identifier: tenant,
          facility_identifier: facility
        )
        @audit_recorded = true
      end

      # The belt behind the sanitizer (F2): a VALIDATION failure is
      # input-shaped — some feeder let a value through that cannot be a
      # lawful entity — and must never become an unrecorded 503. The row is
      # retried once with the entity omitted, and the omission is stated on
      # the row. A store failure (StatementInvalid, connectivity) is NOT
      # rescued: that is the genuine fail-closed case.
      # `detached:` writes on a connection of its own (see
      # AuditEvent.create_detached!): the exception path's row must survive a
      # caller-owned parent transaction rolling back on the re-raised error
      # (F3) — the normal path stays INSIDE the wrapper's transaction, which
      # is what makes the action's writes and their audit row atomic.
      def persist_audit_row!(detached: false, **attrs)
        write = detached ? AuditEvent.method(:create_detached!) : AuditEvent.method(:create!)
        write.call(**attrs)
      rescue ActiveRecord::RecordInvalid => e
        entity_errors = e.record.errors.map(&:full_message).join("; ")
        Rails.logger.warn("[audit] entity omitted from an audit row: #{entity_errors}")
        write.call(**attrs.merge(
          entity_identifier: nil,
          outcome_desc: [ attrs[:outcome_desc],
                          "entity identifier omitted: failed audit-row validation" ].compact.join("; ")
        ))
      end

      # UNDER WHICH CONTEXT. Through the host's configured resolvers, so a
      # deployment that carries tenancy somewhere other than a header (a
      # subdomain, the token) is recorded correctly rather than blank.
      #
      # BOUNDED (review finding on #512): the default resolvers return raw
      # request headers, which are attacker-writable — persisting hundreds
      # of bytes of garbage verbatim into the compliance log is a bloat
      # vector here, and a row-suppressing insert failure on any host whose
      # columns carry length limits. Overlong output is OMITTED and the
      # omission recorded as an anomaly; an audit write must never fail
      # because of request input.
      AUDIT_CONTEXT_VALUE_LIMIT = 255

      def audit_tenant_identifier
        bounded_context_value("tenant", Lakeraven::EHR.configuration.tenant_resolver&.call(request))
      rescue StandardError
        nil
      end

      def audit_facility_identifier
        bounded_context_value("facility", Lakeraven::EHR.configuration.facility_resolver&.call(request))
      rescue StandardError
        nil
      end

      def bounded_context_value(label, value)
        value = value.to_s.presence
        return nil unless value
        return value if value.length <= AUDIT_CONTEXT_VALUE_LIMIT

        note_audit_anomaly("#{label} identifier omitted: exceeds #{AUDIT_CONTEXT_VALUE_LIMIT} characters")
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

      # Detached (F3): the wrapper's own transaction has already rolled back
      # here, but a CALLER-OWNED parent (a service, an importer, a test
      # harness owning its transaction) will still roll back when the
      # exception is re-raised — and a plain insert would join it and vanish.
      # The action truly ran and truly failed; its record survives.
      def record_attempt_after_rollback
        record_audit_event!(detached: true)
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
          @audit_denial_reason.present? || @audit_action_failure ||
          resolved_clinician_duz.present?
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

      # Something about this request does not add up — a token and a session
      # arriving together, most of all. An anomaly is RECORDED, never silently
      # resolved: the row that quietly picks a winner is the row that lies.
      # Deduplicated: the resolver runs more than once per request (once for
      # `auditable_access?`, once for the row itself), and an anomaly noted
      # twice reads like two anomalies.
      def note_audit_anomaly(description)
        @audit_anomalies ||= []
        @audit_anomalies << description unless @audit_anomalies.include?(description)
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

      # A human, if one can be named — but ONLY from the MECHANISM that
      # authenticated (or refused) this request. Round 2 of the gate proved
      # the first version's rule — "no token object means the session
      # authenticated this" — false in both directions:
      #
      #   * A FHIR surface is NEVER session-authenticated. A tokenless or
      #     garbage-token request to it is a REFUSAL, and filing that refusal
      #     under a bystanding browser session names an innocent clinician on
      #     an attempt they never made (F1; with SameSite=Lax any cross-site
      #     link can mint such rows).
      #   * `current_duz` (#486, not on this branch) may only name a human
      #     when the token itself resolves to one — a session-derived
      #     `current_duz` beating token identity would silently reopen S2
      #     (the landmine test pins this).
      #
      # So the resolver branches on mechanism, and each branch may consult
      # only that mechanism's identity:
      #
      #   token present  -> the token's human, and only via #486's
      #                     `browser_sso_token?` proof that the token is the
      #                     session-bound browser token; otherwise the
      #                     token's application answers (in
      #                     audit_agent_attributes) and any session is an
      #                     ANOMALY on the row, never the actor.
      #   no token, and the SURFACE authenticates by session
      #                  -> `current_duz` / `session[:duz]`.
      #   no token, token-authenticated surface
      #                  -> nobody. The refusal is recorded unattributed,
      #                     with any bystanding session noted as an anomaly.
      #
      # Anomalies are RECORDED, never silently resolved — and never invented:
      # a bypass surface (`unauthenticated_audit_actor`) was authenticated by
      # its own gate, so it never consults the session at all.
      def resolved_clinician_duz
        return nil if unauthenticated_audit_actor

        token = audit_current_token
        session_duz = session_value(:duz)

        if token
          if session_bound_browser_token?(token)
            human = current_duz_if_defined || session_duz
            return human if human.present?
          end
          if session_duz.present? || current_duz_if_defined.present?
            note_audit_anomaly(
              "identity anomaly: bearer token (application #{token.application&.uid}) and a browser " \
              "session (DUZ #{session_duz || current_duz_if_defined}) arrived on one request; recorded under the token"
            )
          end
          nil
        elsif session_authenticated_surface?
          current_duz_if_defined || session_duz
        else
          if session_duz.present?
            note_audit_anomaly(
              "identity anomaly: a bystanding browser session (DUZ #{session_duz}) accompanied an " \
              "unauthenticated request to a token-authenticated surface; not used for attribution"
            )
          end
          nil
        end
      end

      # Does this SURFACE authenticate by the browser session? Declared, not
      # inferred: token-object absence is a refusal on an API surface, not a
      # session sign-on (F1). WebController — the browser base whose
      # `require_authentication` gates on `session[:duz]` — declares true;
      # everything else defaults to false.
      def session_authenticated_surface?
        false
      end

      def current_duz_if_defined
        return nil unless respond_to?(:current_duz, true)

        current_duz.presence
      end

      # #486's predicate, behind `respond_to?` because it is a sibling branch.
      # When it is absent we CANNOT prove a token is the session-bound browser
      # token, so the session may not attribute — the closed direction is
      # toward the token's own application identity, never toward a human the
      # request cannot be tied to (see PR #486).
      def session_bound_browser_token?(token)
        return false unless respond_to?(:browser_sso_token?, true)

        browser_sso_token?(token)
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

      # HOW IT ENDED. Three subtleties, each of which filed the wrong outcome
      # in an earlier version:
      #
      #   * An action that RAISED is a failure whatever `response.status`
      #     says — the status is still 200 when the attempt is recorded on
      #     the exception path (S4).
      #   * A redirect is a SUCCESS unless it was a refusal: browser actions
      #     routinely succeed with a 302, and filing them as serious failures
      #     poisons the refusals the log exists to surface. A refusal
      #     redirect carries its `note_audit_denial` reason and is filed as a
      #     determined refusal.
      def audit_outcome
        # A CSRF rejection is a determined refusal, not a serious failure.
        return "4" if csrf_refusal?(@audit_action_failure)
        return "8" if @audit_action_failure

        case response.status
        when 200..299 then "0"   # success
        when 300..399 then @audit_denial_reason.present? ? "4" : "0"
        when 400..499 then "4"   # minor failure (refusal)
        else "8"                 # serious failure
        end
      end

      # The reason(s), composed: the denial reason a refusal renderer noted,
      # the exception CLASS of a raising action (never the message — messages
      # carry record identifiers and worse), and any identity anomaly.
      def audit_outcome_desc
        parts = [ @audit_denial_reason ]
        # The CSRF denial reason already names the class; don't say it twice.
        if @audit_action_failure && !csrf_refusal?(@audit_action_failure)
          parts << "action raised #{@audit_action_failure.class.name}"
        end
        parts.concat(Array(@audit_anomalies))
        combined = parts.compact.join("; ")
        combined.presence
      end

      def csrf_refusal?(error)
        defined?(ActionController::InvalidAuthenticityToken) &&
          error.is_a?(ActionController::InvalidAuthenticityToken)
      end

      # WHAT RECORD the row points at. The entity is a REFERENCE —
      # `<audit_entity_type>/<audit_entity_identifier>` — and this concern is
      # the ONE owner of the rule (round-2 consolidated review): the halves
      # are derived together so they cannot disagree.
      #
      #   * A direct read names the controller's own resource, from a param
      #     that identifies a record OF THAT TYPE — a nested route's `:dfn`
      #     under a non-Patient type produced references like
      #     `QuestionnaireResponse/<dfn>` that resolve to a DIFFERENT
      #     patient's record (#491). `?_id=` is FHIR's search-by-id and
      #     counts as direct.
      #   * A patient-scoped search (`?patient=…`, reference form included)
      #     names the PATIENT whose chart was read. Recording nothing there
      #     made `/audit-review?entity=<dfn>` and the §164.528 export read
      #     EMPTY for a chart that was just opened — absence of data as
      #     determination.
      #
      # SANITIZED, because these params are attacker-influencable request
      # input (F2): a query-string `?id=Observation/9` on a search must not
      # make the audit row invalid — which the fail-closed wrapper would turn
      # into a 503 with NO row, letting any client 5xx every search and
      # letting malformed-identifier probes go unrecorded. An identifier that
      # cannot name a record of the audited type is OMITTED: a row with no
      # entity beats no row, and never a row that lies.
      def audit_entity_type
        audit_entity_reference.first
      end

      def audit_entity_identifier
        audit_entity_reference.last
      end

      # Both halves derived TOGETHER, and degradation runs toward the
      # patient, never away from it: a direct identifier that sanitizes to
      # nothing falls back to the `?patient=` scope when one is present
      # (round-2 close-out) — otherwise appending one garbage `?id=` param
      # would strip patient attribution from the §164.528 trail while the
      # search still served the patient's data.
      def audit_entity_reference
        direct = sanitize_identifier_for(fhir_resource_type, direct_audit_identifier)
        return [ fhir_resource_type, direct ] if direct

        patient = sanitize_identifier_for("Patient", patient_search_param)
        return [ "Patient", patient ] if patient

        [ fhir_resource_type, nil ]
      end

      def direct_audit_identifier
        if fhir_resource_type.to_s == "Patient"
          params[:dfn] || params[:ien] || params[:id] || params[:_id]
        else
          params[:id] || params[:ien] || params[:_id]
        end
      end

      # FHIR allows both `?patient=1` and `?patient=Patient/1`; the gateways
      # accept both (`extract_patient_dfn`), so the audit records both.
      def patient_search_param
        params[:patient].to_s.delete_prefix("Patient/")
      end

      # FHIR R4's "id" grammar. Anything outside it — a reference, markup,
      # hundreds of digits — cannot name a record, so it is never treated as
      # an identifier (review finding on #512: unbounded input reached the
      # log verbatim, and would suppress the row outright on a host schema
      # with column limits).
      FHIR_ID_PATTERN = /\A[A-Za-z0-9\-.]{1,64}\z/

      def sanitize_identifier_for(entity_type, value)
        value = value.to_s.presence
        return nil unless value

        unless value.match?(FHIR_ID_PATTERN)
          note_audit_anomaly("entity identifier omitted: not a valid FHIR id")
          return nil
        end
        return nil if entity_type.to_s == "Patient" && !value.match?(/\A\d+\z/)

        value
      end

      # WHAT KIND of record, derived from the controller, so this concern can
      # be mixed into a browser surface that never defined one. An audit row
      # whose insert raises NoMethodError on a missing helper is a fail-closed
      # 503 on a page that was working — coverage has to be safe to add.
      def fhir_resource_type
        self.class.name.demodulize.delete_suffix("Controller").singularize
      end

      # An action that established non-database state undoes it here: state
      # the audit log has no record of must not survive the request. Session
      # and cookie-jar writes are already rolled back by the deny path; this
      # hook is for anything else — an in-memory store, a file.
      def rollback_unrecorded_access; end

      # Throw away EVERYTHING the action produced, then answer 503.
      #
      # A discarded body is not a discarded response. The same refusal has
      # four other ways to carry out the fact it is refusing:
      #
      #   * the headers — a Location naming the chart, an X-… the action set;
      #   * the flash — which a sibling PR carried out of a 503 in the session
      #     cookie, patient name and all;
      #   * the SESSION and the COOKIE JAR — both committed by MIDDLEWARE
      #     after the controller returns, so clearing response headers here
      #     cannot touch them (S8). The session is restored to its pre-action
      #     snapshot; the cookie jar is rebuilt from the request's own
      #     cookies, which discards every pending write and delete;
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
        discard_unrecorded_session!
        discard_unrecorded_flash!
        discard_unrecorded_cookies!
        render plain: "Service Unavailable: this access could not be recorded, so it was not completed",
               status: :service_unavailable
      end

      # NAMES AND VALUES, both (review finding on #512): snapshotting only
      # names let an action OVERWRITE a pre-existing header — a default
      # security header, most likely — and the PHI-bearing value survived a
      # deletion-by-difference that only knew names. Anything the action
      # added is deleted; anything that predated it is restored to the value
      # it had.
      def capture_header_baseline
        response.headers.to_h.transform_values { |value| value.dup }.freeze
      rescue StandardError
        response.headers.to_h.freeze
      end

      def discard_unrecorded_headers!
        baseline = @audit_header_baseline || {}
        (response.headers.to_h.keys - baseline.keys).each { |name| response.delete_header(name) }
        baseline.each { |name, value| response.set_header(name, value) }
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

      # -- S8: the two channels middleware commits AFTER the controller -----

      def capture_session_baseline
        return nil unless respond_to?(:session, true)

        session.to_hash.deep_dup
      rescue StandardError
        # No session middleware on this surface (an API-only stack).
        nil
      end

      # Restore the session to what it held BEFORE the action ran. Restoring
      # (rather than clearing) matters in both directions: state the action
      # wrote must not survive an unrecorded access, and state the action did
      # NOT write — the clinician's sign-in — must not be destroyed by one,
      # or every audit outage becomes a logout.
      #
      # Fail closed: if the pre-action snapshot could not be taken, the whole
      # session is dropped rather than allowed out carrying unrecorded state.
      def discard_unrecorded_session!
        return unless respond_to?(:session, true)

        if @audit_session_baseline
          session.clear
          session.update(@audit_session_baseline)
        else
          session.clear
        end
      rescue StandardError => e
        Rails.logger.error("[audit] could not roll back the session on a refused access: #{e.message}")
        begin
          session.clear
        rescue StandardError
          nil
        end
      end

      # The cookie jar's pending writes are not response headers yet — the
      # Cookies middleware serializes them after the controller returns.
      # Rebuilding the jar from the REQUEST's own cookies discards every
      # pending set and delete; if the jar cannot be rebuilt, it is removed
      # outright so the middleware finds nothing to write.
      def discard_unrecorded_cookies!
        return unless request.respond_to?(:have_cookie_jar?) && request.have_cookie_jar?

        request.cookie_jar = ActionDispatch::Cookies::CookieJar.build(request, request.cookies)
      rescue StandardError => e
        Rails.logger.error("[audit] could not roll back the cookie jar on a refused access: #{e.message}")
        request.env.delete("action_dispatch.cookies")
      end
    end
  end
end
