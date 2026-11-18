# frozen_string_literal: true

module Lakeraven
  module EHR
    # Proof, before an RPC write, that the audit log can take a row.
    #
    # An RPMS write cannot join the audit transaction, so a failed audit
    # cannot undo it. A controller that writes through an RPC inserts a probe
    # row and rolls it back first. If the insert raises, the log cannot
    # record this access, and the write must not run. The row that remains is
    # the one AuditableClinicalAccess writes once the response is known.
    #
    # The including controller names its log tag (audit_probe_log_tag) and
    # the patient the probe row is for (audit_probe_dfn).
    module AuditLogProbe
      extend ActiveSupport::Concern

      private

      # Class only in the log line. The insert error's message can carry
      # broker or database text.
      def audit_log_writable?
        AuditEvent.transaction(requires_new: true) do
          AuditEvent.create!(probe_audit_attributes)
          raise ActiveRecord::Rollback
        end
        true
      rescue StandardError => error
        Rails.logger.warn("[#{audit_probe_log_tag}] audit log did not accept a row: #{error.class}")
        false
      end

      def probe_audit_attributes
        dfn = audit_probe_dfn
        {
          event_type: "rest",
          action: "C",
          outcome: "0",
          entity_type: "Patient",
          entity_identifier: Patient.canonical_dfn(dfn) || dfn.to_s
        }
      end
    end
  end
end
