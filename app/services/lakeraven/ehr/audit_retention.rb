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
      def purge!(now: Time.current)
        enforce_policy_floor!

        doomed = purgeable(now)
        count = doomed.count
        return 0 if count.zero?

        doomed.delete_all
        record_purge!(count, now)
        count
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
          **AuditContext.agent_attributes
        )
      end
    end
  end
end
