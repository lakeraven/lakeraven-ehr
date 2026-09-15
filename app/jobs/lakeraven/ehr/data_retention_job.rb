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

      RETENTION_POLICIES = {
        "Disclosure" => 2190 # 6 years per HIPAA
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
      def purge_audit_events
        { purged: AuditRetention.purge!, cutoff: AuditRetention.cutoff.iso8601 }
      rescue AuditRetention::RetentionPolicyError => e
        { skipped: true, reason: e.message }
      end

      def purge_expired(model_name, retention_days)
        cutoff = retention_days.days.ago
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
