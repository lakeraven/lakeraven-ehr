# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EmergencyAccessServiceTest < ActiveSupport::TestCase
      setup do
        @audit_log = []
        @attrs = {
          patient_dfn: "12345",
          accessed_by: "789",
          reason: "medical_emergency",
          justification: "Patient unresponsive"
        }
      end

      # =============================================================================
      # GRANTING ACCESS
      # =============================================================================

      # The model callback only covers `EmergencyAccess.create!`, but THIS
      # service is the public break-glass workflow — and its grants appended
      # a hash to the caller's in-memory `audit_log` and touched no shared
      # AuditEvent at all. Break-glass is the access most worth a row.
      test "granting through the service leaves a shared AuditEvent row" do
        AuditEvent.delete_all

        assert_difference -> { AuditEvent.count }, 1 do
          EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)
        end

        event = AuditEvent.order(:id).last
        assert_equal "security", event.event_type
        assert_equal [ "Patient", "12345" ], [ event.entity_type, event.entity_identifier ]
        assert_equal [ "Practitioner", "789" ], [ event.agent_who_type, event.agent_who_identifier ]
        assert_match(/break-glass/i, event.outcome_desc.to_s)
      end

      test "the service's shared row carries the reason code, never the justification" do
        AuditEvent.delete_all
        EmergencyAccessService.grant(**@attrs, justification: "Patient SYNTHETIC,NAME collapsed in the lobby",
                                     audit_log: @audit_log)

        event = AuditEvent.order(:id).last
        refute_includes event.attributes.values.compact.map(&:to_s).join(" "), "SYNTHETIC,NAME",
          "the free-text justification reached the shared audit log"
      end

      test "a grant whose shared audit cannot be written raises instead of granting silently" do
        AuditEvent.define_singleton_method(:create!) do |*|
          raise ActiveRecord::StatementInvalid, "audit store unavailable"
        end

        assert_raises(ActiveRecord::StatementInvalid) do
          EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)
        end
      ensure
        AuditEvent.singleton_class.send(:remove_method, :create!)
      end

      test "reviewing through the service leaves a shared AuditEvent row" do
        AuditEvent.delete_all
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)

        assert_difference -> { AuditEvent.count }, 1 do
          EmergencyAccessService.review(emergency_access: access, reviewer_duz: "456",
                                        outcome: "appropriate", audit_log: @audit_log)
        end

        event = AuditEvent.order(:id).last
        assert_equal "456", event.agent_who_identifier
        assert_match(/review/i, event.outcome_desc.to_s)
      end

      test "grant creates an emergency access record" do
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)

        assert_equal "12345", access.patient_dfn
        assert_equal "medical_emergency", access.reason
        assert access.accessed_at.present?
      end

      test "grant sets default 4-hour expiration" do
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)
        expected = access.accessed_at + 4.hours

        assert_in_delta expected, access.expires_at, 2.seconds
      end

      test "grant accepts custom duration" do
        access = EmergencyAccessService.grant(**@attrs, duration: 2.hours, audit_log: @audit_log)
        expected = access.accessed_at + 2.hours

        assert_in_delta expected, access.expires_at, 2.seconds
      end

      test "grant creates a security audit entry" do
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)

        assert_equal 1, @audit_log.length
        audit = @audit_log.first
        assert_equal "security", audit[:event_type]
        assert_equal "emergency_access.grant", audit[:subtype]
        assert_equal "E", audit[:action]
        assert_equal "789", audit[:agent_who_id]
        assert_equal "Practitioner", audit[:agent_who_type]
        assert_equal "BTG", audit[:purpose_of_event]
      end

      test "grant raises on invalid reason" do
        assert_raises(EmergencyAccessService::InvalidReasonError) do
          EmergencyAccessService.grant(**@attrs.merge(reason: "invalid"), audit_log: @audit_log)
        end
      end

      # =============================================================================
      # REVIEWING ACCESS
      # =============================================================================

      test "review marks access as reviewed" do
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)
        EmergencyAccessService.review(
          emergency_access: access,
          reviewer_duz: "SUP1",
          outcome: "appropriate",
          notes: "Justified by clinical situation",
          audit_log: @audit_log
        )

        assert access.reviewed?
        assert_equal "SUP1", access.reviewed_by
        assert_equal "appropriate", access.review_outcome
        assert_equal "Justified by clinical situation", access.review_notes
      end

      test "review creates a security audit entry" do
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)
        @audit_log.clear
        EmergencyAccessService.review(
          emergency_access: access,
          reviewer_duz: "SUP1",
          outcome: "inappropriate",
          audit_log: @audit_log
        )

        assert_equal 1, @audit_log.length
        audit = @audit_log.first
        assert_equal "security", audit[:event_type]
        assert_equal "emergency_access.review", audit[:subtype]
        assert_equal "U", audit[:action]
        assert_equal "BTG", audit[:purpose_of_event]
      end

      test "review raises if already reviewed" do
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)
        EmergencyAccessService.review(
          emergency_access: access,
          reviewer_duz: "SUP1",
          outcome: "appropriate",
          audit_log: @audit_log
        )

        assert_raises(EmergencyAccessService::AlreadyReviewedError) do
          EmergencyAccessService.review(
            emergency_access: access,
            reviewer_duz: "SUP2",
            outcome: "inappropriate",
            audit_log: @audit_log
          )
        end
      end

      test "review raises on invalid outcome" do
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)

        assert_raises(EmergencyAccessService::InvalidReviewOutcomeError) do
          EmergencyAccessService.review(
            emergency_access: access,
            reviewer_duz: "SUP1",
            outcome: "looks_fine",
            audit_log: @audit_log
          )
        end
      end

      # =============================================================================
      # ACTIVE ACCESS CHECK
      # =============================================================================

      test "active? returns true for unexpired access" do
        access = EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)

        assert access.active?
      end

      test "active? returns false for expired access" do
        access = EmergencyAccessService.grant(**@attrs, duration: 0.seconds, audit_log: @audit_log)

        assert_not access.active?
      end

      # =============================================================================
      # PENDING REVIEWS
      # =============================================================================

      test "pending_reviews returns unreviewed accesses from collection" do
        accesses = []
        accesses << EmergencyAccessService.grant(**@attrs, audit_log: @audit_log)
        accesses << EmergencyAccessService.grant(**@attrs.merge(accessed_by: "456"), audit_log: @audit_log)
        reviewed = EmergencyAccessService.grant(**@attrs.merge(accessed_by: "111"), audit_log: @audit_log)
        accesses << reviewed
        EmergencyAccessService.review(emergency_access: reviewed, reviewer_duz: "SUP1", outcome: "appropriate", audit_log: @audit_log)

        pending = EmergencyAccessService.pending_reviews(accesses)

        assert_equal 2, pending.length
      end
    end
  end
end
