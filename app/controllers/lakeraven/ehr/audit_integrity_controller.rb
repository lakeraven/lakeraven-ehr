# frozen_string_literal: true

module Lakeraven
  module EHR
    # The audit log's integrity posture, for the person whose job is to
    # trust it — or to know precisely why they cannot yet.
    #
    # Everything on this screen is an INSTALLED FACT, asked of the running
    # database and the running configuration, never a capability of the
    # adapter (#507 gate finding S1: a capability probe was reported as an
    # installation fact, over a database where the control was absent).
    class AuditIntegrityController < WebController
      include AuditReviewerAuthorization

      def show
        @tamper_evident = AuditEvent.tamper_evident?
        @integrity_mode = AuditEvent.integrity_mode
        @digest_keyed = AuditEvent.digest_key.present?
        @append_only_installed = AuditEvent.append_only_installed?
        @append_only_capable = AuditEvent.append_only_enforceable?
        @unverified = AuditEvent.tampered_events
      end

      private

      def fhir_resource_type = "AuditEvent"
      def audit_entity_identifier = nil
    end
  end
end
