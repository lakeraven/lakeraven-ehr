# frozen_string_literal: true

module Lakeraven
  module EHR
    # Enforces data retention policies for audit and session data.
    # Purges expired records based on configurable retention periods.
    class DataRetentionJob < ApplicationJob
      queue_as :low_priority

      RETENTION_POLICIES = {
        "AuditEvent" => 365,
        "Disclosure" => 2190 # 6 years per HIPAA
      }.freeze

      def perform
        results = {}

        RETENTION_POLICIES.each do |model_name, retention_days|
          results[model_name] = purge_expired(model_name, retention_days)
        end

        results
      end

      private

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
