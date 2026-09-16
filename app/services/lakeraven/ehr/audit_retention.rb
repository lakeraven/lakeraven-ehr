# frozen_string_literal: true

module Lakeraven
  module EHR
    # How long PHI access records are kept, and the only way they leave.
    #
    # HIPAA §164.316(b)(2)(i) requires six years. That is a FLOOR: a host may
    # keep records longer for a state rule or a tribal records policy, and a
    # shorter setting is refused rather than honoured — a purge that reaches
    # inside the retention window destroys records the rule still requires,
    # and it would do it quietly.
    #
    # The purge leaves its own audit row behind. A deletion nobody can see is
    # the one thing worse than keeping the records too long.
    module AuditRetention
      class RetentionPolicyError < StandardError; end

      module_function

      def retention_period
        Lakeraven::EHR.configuration.audit_retention_period ||
          Lakeraven::EHR::Configuration::MINIMUM_AUDIT_RETENTION
      end

      def cutoff(now = Time.current)
        now - retention_period
      end

      def purgeable(now = Time.current)
        AuditEvent.occurring_before(cutoff(now))
      end

      # Returns the number of records removed.
      #
      # THE DELETION AND ITS RECEIPT ARE ONE TRANSACTION (S5 on #507): the
      # first version deleted, then recorded, outside any transaction, so a
      # failed receipt left a silent hole inside the six-year floor — and
      # integrity over what remained read clean. If the receipt cannot be
      # written, nothing is deleted and the error surfaces.
      def purge!(now: Time.current)
        enforce_policy_floor!

        AuditEvent.transaction do
          doomed = purgeable(now)
          count = doomed.count
          if count.zero?
            0
          else
            doomed.delete_all
            record_purge!(count, now)
            count
          end
        end
      end

      def enforce_policy_floor!
        minimum = Lakeraven::EHR::Configuration::MINIMUM_AUDIT_RETENTION
        return if retention_period >= minimum

        raise RetentionPolicyError,
              "audit_retention_period is #{retention_period.inspect}; policy requires at least 6 years " \
              "(HIPAA 164.316(b)(2)(i)). Refusing to purge."
      end

      def record_purge!(count, now)
        AuditEvent.create!(
          event_type: "application",
          action: "D",
          outcome: "0",
          outcome_desc: "Retention purge removed #{count} audit event(s) recorded before #{cutoff(now).iso8601}",
          entity_type: "AuditEvent",
          **purge_agent_attributes
        )
      end

      # AuditContext ships with the audit-core part of the #507 split
      # (PR #512), a SIBLING of this branch that may not have landed. Absent
      # it, the purge is recorded UNATTRIBUTED — never guessed, never
      # skipped. `rescue NameError` rather than `defined?` because Zeitwerk
      # resolves the constant lazily.
      def purge_agent_attributes
        AuditContext.agent_attributes
      rescue NameError
        { agent_who_type: "Unknown", agent_who_identifier: nil }
      end
    end
  end
end
