# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AuditEventTest < ActiveSupport::TestCase
      teardown do
        AuditEvent.delete_all
      end

      # =============================================================================
      # VALIDATION TESTS
      # =============================================================================

      test "should be valid with required attributes" do
        audit_event = AuditEvent.new(
          event_type: "rest",
          action: "R",
          outcome: "0",
          entity_type: "Patient",
          agent_who_type: "Practitioner",
          agent_who_identifier: "101"
        )
        assert audit_event.valid?, "AuditEvent should be valid with required attributes"
      end

      test "should require event_type" do
        audit_event = AuditEvent.new(
          action: "R",
          outcome: "0",
          entity_type: "Patient",
          agent_who_identifier: "101"
        )
        refute audit_event.valid?
        assert audit_event.errors[:event_type].any?
      end

      test "should require action" do
        audit_event = AuditEvent.new(
          event_type: "rest",
          outcome: "0",
          entity_type: "Patient",
          agent_who_identifier: "101"
        )
        refute audit_event.valid?
        assert audit_event.errors[:action].any?
      end

      test "should require outcome" do
        audit_event = AuditEvent.new(
          event_type: "rest",
          action: "R",
          entity_type: "Patient",
          agent_who_identifier: "101"
        )
        refute audit_event.valid?
        assert audit_event.errors[:outcome].any?
      end

      test "should require entity_type" do
        audit_event = AuditEvent.new(
          event_type: "rest",
          action: "R",
          outcome: "0",
          agent_who_identifier: "101"
        )
        refute audit_event.valid?
        assert audit_event.errors[:entity_type].any?
      end

      # =============================================================================
      # PERSISTENCE TESTS
      # =============================================================================

      test "persisted? returns false for new audit event" do
        audit_event = AuditEvent.new(event_type: "rest", action: "R", outcome: "0", entity_type: "Patient")
        refute audit_event.persisted?
      end

      test "persisted? returns true for saved audit event" do
        audit_event = AuditEvent.new(
          event_type: "rest",
          action: "R",
          outcome: "0",
          entity_type: "Patient",
          agent_who_identifier: "101"
        )
        audit_event.save!
        assert audit_event.persisted?
      end

      test "save creates audit event" do
        audit_event = AuditEvent.new(
          event_type: "rest",
          action: "R",
          outcome: "0",
          entity_type: "Patient",
          agent_who_type: "Practitioner",
          agent_who_identifier: "101"
        )
        assert audit_event.save
        assert audit_event.persisted?
        assert audit_event.id.present?
      end

      test "create! returns saved audit event" do
        audit_event = AuditEvent.create!(
          event_type: "rest",
          action: "R",
          outcome: "0",
          entity_type: "Patient",
          agent_who_type: "Practitioner",
          agent_who_identifier: "101"
        )
        assert audit_event.persisted?
        assert_equal "rest", audit_event.event_type
      end

      # =============================================================================
      # IMMUTABILITY TESTS
      # =============================================================================

      test "audit rows are immutable" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Application", agent_who_identifier: "test-app"
        )

        assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(outcome: "4") }
      end

      # =============================================================================
      # SCOPE TESTS
      # =============================================================================

      test "recent scope returns newest first" do
        old = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Application", agent_who_identifier: "app1"
        )

        new_event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "2",
          agent_who_type: "Application", agent_who_identifier: "app2"
        )

        assert_equal new_event.id, AuditEvent.recent.first.id
      end

      # =============================================================================
      # NEW COLUMN TESTS (outcome_desc, agent_name, agent_network_address, entity_id)
      # =============================================================================

      test "stores outcome_desc" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "8",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Application", agent_who_identifier: "test-app",
          outcome_desc: "Connection timeout"
        )

        assert_equal "Connection timeout", event.reload.outcome_desc
      end

      test "stores agent_name" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Practitioner", agent_who_identifier: "101",
          agent_name: "MARTINEZ,SARAH"
        )

        assert_equal "MARTINEZ,SARAH", event.reload.agent_name
      end

      test "stores agent_network_address" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Application", agent_who_identifier: "test-app",
          agent_network_address: "192.168.1.100"
        )

        assert_equal "192.168.1.100", event.reload.agent_network_address
      end

      test "stores entity_id" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Application", agent_who_identifier: "test-app",
          entity_id: "patient-uuid-123"
        )

        assert_equal "patient-uuid-123", event.reload.entity_id
      end

      test "handles nil optional columns" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient",
          agent_who_type: "Application", agent_who_identifier: "test-app",
          outcome_desc: nil,
          agent_name: nil,
          agent_network_address: nil,
          entity_id: nil
        )

        assert event.persisted?
        assert_nil event.outcome_desc
        assert_nil event.agent_name
        assert_nil event.agent_network_address
        assert_nil event.entity_id
      end

      # =============================================================================
      # VALIDATES REQUIRED FIELDS (combined)
      # =============================================================================

      test "validates required fields" do
        event = AuditEvent.new
        assert_not event.valid?
        assert_includes event.errors[:event_type], "can't be blank"
        assert_includes event.errors[:action], "can't be blank"
        assert_includes event.errors[:outcome], "can't be blank"
        assert_includes event.errors[:entity_type], "can't be blank"
      end
    end
  end
end
