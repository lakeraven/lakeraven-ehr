# frozen_string_literal: true

module Lakeraven
  module EHR
    # Auditable concern for ActiveJob classes.
    # Creates an AuditEvent after job execution (success or failure).
    # PHI is scrubbed from error messages before logging.
    module Auditable
      extend ActiveSupport::Concern

      PHI_PATTERNS = [
        /\b\d{3}-\d{2}-\d{4}\b/,           # SSN
        /\b[A-Z]+,[A-Z]+(?:\s[A-Z])?\b/i,  # LAST,FIRST format
        /\bDFN[:\s]*\d+\b/i,               # DFN references
        /\bPatient\s+DFN[:\s]*\d+\b/i      # Patient DFN references
      ].freeze

      included do
        after_perform :record_success_audit
        rescue_from(StandardError) do |exception|
          record_failure_audit(exception)
          raise
        end
      end

      private

      def record_success_audit
        AuditEvent.create!(
          event_type: "application",
          action: "E",
          outcome: "0",
          entity_type: "Job",
          entity_identifier: self.class.name
        )
      end

      def record_failure_audit(exception)
        AuditEvent.create!(
          event_type: "application",
          action: "E",
          outcome: "8",
          entity_type: "Job",
          entity_identifier: self.class.name,
          outcome_desc: sanitize_phi(exception.message)
        )
      end

      def sanitize_phi(message)
        result = message.dup
        PHI_PATTERNS.each { |pattern| result.gsub!(pattern, "[REDACTED]") }
        result
      end
    end
  end
end
