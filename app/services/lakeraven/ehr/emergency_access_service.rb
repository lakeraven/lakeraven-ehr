# frozen_string_literal: true

module Lakeraven
  module EHR
    # EmergencyAccessService — Break-the-glass emergency access workflow
    #
    # ONC § 170.315(d)(6) — Emergency Access
    #
    # Provides a service layer for granting emergency access to patient data,
    # enhanced audit logging, and post-access supervisor review.
    #
    # Ported from the predecessor app EmergencyAccessService.
    class EmergencyAccessService
      class AlreadyReviewedError < StandardError; end
      class InvalidReviewOutcomeError < StandardError; end
      class InvalidReasonError < StandardError; end

      VALID_REASONS = %w[
        medical_emergency
        public_health
        authorized_break_glass
      ].freeze

      REVIEW_OUTCOMES = %w[appropriate inappropriate].freeze

      DEFAULT_DURATION = 4.hours

      # Lightweight emergency access record (ActiveModel-style)
      class EmergencyAccess
        attr_accessor :patient_dfn, :accessed_by, :accessed_by_name,
                      :reason, :justification, :accessed_at, :expires_at,
                      :reviewed_by, :reviewed_by_name, :reviewed_at,
                      :review_outcome, :review_notes

        def initialize(attrs = {})
          attrs.each { |k, v| public_send(:"#{k}=", v) }
        end

        def reviewed?
          reviewed_at.present?
        end

        def active?
          expires_at.present? && Time.current < expires_at
        end
      end

      def self.grant(patient_dfn:, accessed_by:, reason:, justification: nil,
                     accessed_by_name: nil, duration: DEFAULT_DURATION, audit_log: [])
        unless VALID_REASONS.include?(reason)
          raise InvalidReasonError, "Invalid reason '#{reason}'. Must be one of: #{VALID_REASONS.join(', ')}"
        end

        now = Time.current
        access = EmergencyAccess.new(
          patient_dfn: patient_dfn,
          accessed_by: accessed_by,
          accessed_by_name: accessed_by_name,
          reason: reason,
          justification: justification,
          accessed_at: now,
          expires_at: now + duration
        )

        record_grant_audit(access, audit_log)
        # The SHARED, persisted trail (review finding on #512): the hash
        # appended above is the predecessor app's in-memory contract and
        # reaches no reviewer. Break-glass is the access most worth a row,
        # so the grant also writes into the same AuditEvent log everything
        # else uses — the reason CODE only, never the free-text
        # justification (ADR 0002) — and FAILS CLOSED: if the glass cannot
        # be broken audibly, it is not broken.
        record_shared_grant_audit!(access)
        access
      end

      def self.review(emergency_access:, reviewer_duz:, outcome:, notes: nil, reviewer_name: nil, audit_log: [])
        unless REVIEW_OUTCOMES.include?(outcome)
          raise InvalidReviewOutcomeError, "Invalid review outcome '#{outcome}'. Must be one of: #{REVIEW_OUTCOMES.join(', ')}"
        end

        raise AlreadyReviewedError, "Emergency access has already been reviewed" if emergency_access.reviewed?

        emergency_access.reviewed_by = reviewer_duz
        emergency_access.reviewed_by_name = reviewer_name
        emergency_access.reviewed_at = Time.current
        emergency_access.review_outcome = outcome
        emergency_access.review_notes = notes

        record_review_audit(emergency_access, reviewer_duz, outcome, audit_log)
        # Same rule as the grant: the review lands in the shared log too —
        # outcome is a closed enum word, the free-text notes stay off it.
        record_shared_review_audit!(emergency_access, reviewer_duz, outcome)
      end

      def self.pending_reviews(accesses)
        accesses.reject(&:reviewed?)
      end

      def self.record_grant_audit(access, audit_log)
        audit_log << {
          event_type: "security",
          subtype: "emergency_access.grant",
          action: "E",
          recorded: Time.current,
          agent_who_id: access.accessed_by,
          agent_who_type: "Practitioner",
          agent_name: access.accessed_by_name || access.accessed_by,
          entity_type: "EmergencyAccess",
          entity_role: "emergency_access",
          outcome: "0",
          outcome_desc: "Emergency access granted to patient #{access.patient_dfn} " \
                        "for #{access.reason} (expires #{access.expires_at.iso8601})",
          purpose_of_event: "BTG"
        }
      end
      private_class_method :record_grant_audit

      def self.record_review_audit(access, reviewer_duz, outcome, audit_log)
        audit_log << {
          event_type: "security",
          subtype: "emergency_access.review",
          action: "U",
          recorded: Time.current,
          agent_who_id: reviewer_duz,
          agent_who_type: "Practitioner",
          agent_name: access.reviewed_by_name || reviewer_duz,
          entity_type: "EmergencyAccess",
          entity_role: "emergency_access",
          outcome: "0",
          outcome_desc: "Emergency access reviewed as #{outcome} " \
                        "for patient #{access.patient_dfn}",
          purpose_of_event: "BTG"
        }
      end
      private_class_method :record_review_audit

      def self.record_shared_grant_audit!(access)
        AuditEvent.create!(
          event_type: "security",
          action: "E",
          outcome: "0",
          outcome_desc: "Emergency access (break-glass): #{access.reason}, expires #{access.expires_at&.iso8601}",
          entity_type: "Patient",
          entity_identifier: access.patient_dfn,
          agent_who_type: "Practitioner",
          agent_who_identifier: access.accessed_by,
          agent_name: access.accessed_by_name,
          agent_network_address: AuditContext.network_address,
          tenant_identifier: AuditContext.tenant_identifier,
          facility_identifier: AuditContext.facility_identifier
        )
      end
      private_class_method :record_shared_grant_audit!

      def self.record_shared_review_audit!(access, reviewer_duz, outcome)
        AuditEvent.create!(
          event_type: "security",
          action: "U",
          outcome: "0",
          outcome_desc: "Emergency access review: #{outcome}",
          entity_type: "Patient",
          entity_identifier: access.patient_dfn,
          agent_who_type: "Practitioner",
          agent_who_identifier: reviewer_duz,
          agent_name: access.reviewed_by_name,
          agent_network_address: AuditContext.network_address,
          tenant_identifier: AuditContext.tenant_identifier,
          facility_identifier: AuditContext.facility_identifier
        )
      end
      private_class_method :record_shared_review_audit!
    end
  end
end
