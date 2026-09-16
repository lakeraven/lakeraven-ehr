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
    module AuditReviewerAuthorization
      extend ActiveSupport::Concern

      included do
        before_action :require_authentication
        before_action :require_audit_reviewer!
      end

      private

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
      # a row, never the log it is refusing. `note_audit_denial` ships with
      # the audit-core part of the split (PR #512); until it lands the
      # refusal still refuses, it just is not yet recorded.
      def refuse_audit_review(audit_reason, message)
        note_audit_denial(audit_reason) if respond_to?(:note_audit_denial, true)
        render plain: message, status: :forbidden
      end
    end
  end
end
