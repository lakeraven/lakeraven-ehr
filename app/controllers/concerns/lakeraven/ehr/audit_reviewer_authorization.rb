# frozen_string_literal: true

module Lakeraven
  module EHR
    # Who may read about the PHI access log.
    #
    # Shared by the audit review screen and the integrity screen. Carried
    # BYTE-IDENTICALLY by the two PRs of the #507 split that need it
    # (tamper-evidence/retention and review-surface), so either lands
    # cleanly first — if you change it in one branch, change it in both.
    #
    # Empty configuration is NOT "no restriction". The RPMS security key that
    # means "may read the audit log" differs per site, and inventing a
    # default here would open the log to whatever that name happens to mean
    # at a real deployment. An empty list refuses everyone.
    #
    # An attempt to read the audit log is exactly the attempt worth keeping,
    # so refusals here are recorded even before the fail-closed audit core
    # (#512) lands: with the core present, its wrapper records the noted
    # denial; without it, this concern writes the refusal row itself. The
    # `@audit_recorded` interlock keeps it to at most one row either way.
    module AuditReviewerAuthorization
      extend ActiveSupport::Concern

      included do
        before_action :require_authentication
        before_action :require_audit_reviewer!
      end

      private

      # Overrides WebController's base guard ONLY when the audit core
      # (#512) is absent, to record the anonymous probe this branch would
      # otherwise lose. With the core present, the base method already notes
      # the denial and the around_action records it.
      def require_authentication
        return if session[:duz].present?
        return super if respond_to?(:note_audit_denial, true)

        record_audit_refusal("audit review refused: not signed in")
        redirect_to login_path, alert: "Please sign in"
      end

      def require_audit_reviewer!
        allowed = Array(Lakeraven::EHR.configuration.audit_review_security_keys).map(&:to_s)

        if allowed.empty?
          return refuse_audit_review(
            "audit review refused: no reviewer security key is configured",
            "Audit review is not configured. A site administrator must set " \
            "`audit_review_security_keys` before the audit log can be read here."
          )
        end

        return if (current_security_keys.map(&:to_s) & allowed).any?

        refuse_audit_review(
          "audit review refused: #{session[:duz]} holds no reviewer security key",
          "Forbidden: reading the PHI access log requires an audit-reviewer security key."
        )
      end

      # The refusal names the reason and nothing else — never a count, never
      # a row, never the log it is refusing.
      def refuse_audit_review(audit_reason, message)
        note_audit_denial(audit_reason) if respond_to?(:note_audit_denial, true)
        record_audit_refusal(audit_reason) unless respond_to?(:note_audit_denial, true)
        render plain: message, status: :forbidden
      end

      # Best effort, loudly: a refusal that cannot be recorded is still
      # refused (the closed direction), and the failure is logged rather
      # than swallowed. Sets the one-row-per-request interlock so the #512
      # wrapper, when present, does not double-record.
      def record_audit_refusal(reason)
        AuditEvent.create!(
          event_type: "rest",
          action: "R",
          outcome: "4",
          outcome_desc: reason,
          entity_type: "AuditEvent",
          entity_identifier: nil,
          **reviewer_agent_attributes,
          agent_network_address: request.remote_ip,
          tenant_identifier: resolve_audit_context(:tenant_resolver),
          facility_identifier: resolve_audit_context(:facility_resolver)
        )
        @audit_recorded = true
      rescue StandardError => e
        Rails.logger.error("[audit] could not record a refused audit-review attempt: #{e.message}")
      end

      def reviewer_agent_attributes
        if session[:duz].present?
          { agent_who_type: "Practitioner", agent_who_identifier: session[:duz],
            agent_name: session[:user_name].presence }
        else
          { agent_who_type: "Unknown", agent_who_identifier: nil }
        end
      end

      def resolve_audit_context(resolver_name)
        Lakeraven::EHR.configuration.public_send(resolver_name)&.call(request)
      rescue StandardError
        nil
      end
    end
  end
end
