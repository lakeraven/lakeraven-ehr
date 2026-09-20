# frozen_string_literal: true

module Lakeraven
  module EHR
    # Enforces data retention policies for audit and session data.
    # Purges expired records based on configurable retention periods.
    #
    # PHI ACCESS RECORDS ARE NOT PURGED HERE. They used to be, after 365 days
    # — five years inside the window §164.316(b)(2)(i) requires, on a
    # low-priority queue, returning a count. They now go through
    # AuditRetention, which holds the six-year floor, refuses a shortened
    # setting rather than honouring it, and leaves a receipt in the log it
    # just deleted from.
    class DataRetentionJob < ApplicationJob
      queue_as :low_priority

      # CALENDAR years, not day counts (S15 on #507): "6 years" written as
      # 2190 days deleted §164.528 disclosure records one to two days INSIDE
      # their window, because six calendar years span 2191–2192 days across
      # leap years. Durations here; `purge_expired` computes the cutoff with
      # calendar arithmetic.
      RETENTION_POLICIES = {
        "Disclosure" => 6.years # HIPAA §164.528
      }.freeze

      def perform
        results = {}

        RETENTION_POLICIES.each do |model_name, retention_days|
          results[model_name] = purge_expired(model_name, retention_days)
        end

        results["AuditEvent"] = purge_audit_events
        results
      end

      private

      # Delegated rather than duplicated: one place decides how long a PHI
      # access record lives, and it is the place that knows the floor.
      #
      # A refused purge is an ERROR, not a skip: "skipped" reads as routine,
      # and a purge that silently never runs leaves an unbounded log nobody
      # notices until it matters.
      def purge_audit_events
        { purged: AuditRetention.purge!, cutoff: AuditRetention.cutoff.iso8601 }
      rescue AuditRetention::RetentionPolicyError => e
        { error: e.message }
      end

      def purge_expired(model_name, retention)
        cutoff = retention.is_a?(ActiveSupport::Duration) ? retention.ago : retention.days.ago
        klass = "Lakeraven::EHR::#{model_name}".safe_constantize || model_name.safe_constantize

        unless klass
          return { skipped: true, reason: "model not found" }
        end

        if klass.respond_to?(:where) && klass.respond_to?(:delete_all)
          count = klass.where("created_at < ?", cutoff).delete_all
          { purged: count, cutoff: cutoff.iso8601 }
        else
          { skipped: true, reason: "model does not support retention queries" }
        end
      rescue => e
        { error: e.message }
      end
    end
  end
end
