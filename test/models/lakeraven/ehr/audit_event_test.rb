# frozen_string_literal: true

require "test_helper"
require "ostruct"

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

      # =============================================================================
      # ACTION VALIDATION
      # =============================================================================

      test "validates action is in allowed list" do
        event = AuditEvent.new(
          event_type: "rest", action: "X", outcome: "0",
          entity_type: "Patient", agent_who_identifier: "101"
        )
        refute event.valid?
        assert_includes event.errors[:action], "is not included in the list"
      end

      test "validates outcome is in allowed list" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "99",
          entity_type: "Patient", agent_who_identifier: "101"
        )
        refute event.valid?
        assert_includes event.errors[:outcome], "is not included in the list"
      end

      # =============================================================================
      # EVENT TYPE HELPER TESTS
      # =============================================================================

      test "event_type_display returns human-readable type" do
        event = AuditEvent.new(event_type: "rest")
        assert_equal "RESTful Operation", event.event_type_display

        event.event_type = "security"
        assert_equal "Security", event.event_type_display
      end

      # =============================================================================
      # ACTION HELPER TESTS
      # =============================================================================

      test "create_action? returns true for C action" do
        assert AuditEvent.new(action: "C").create_action?
      end

      test "read_action? returns true for R action" do
        assert AuditEvent.new(action: "R").read_action?
      end

      test "update_action? returns true for U action" do
        assert AuditEvent.new(action: "U").update_action?
      end

      test "delete_action? returns true for D action" do
        assert AuditEvent.new(action: "D").delete_action?
      end

      test "execute_action? returns true for E action" do
        assert AuditEvent.new(action: "E").execute_action?
      end

      test "action_display returns human-readable action" do
        assert_equal "Read", AuditEvent.new(action: "R").action_display
        assert_equal "Create", AuditEvent.new(action: "C").action_display
      end

      # =============================================================================
      # OUTCOME HELPER TESTS
      # =============================================================================

      test "success? returns true for outcome 0" do
        assert AuditEvent.new(outcome: "0").success?
      end

      test "minor_failure? returns true for outcome 4" do
        assert AuditEvent.new(outcome: "4").minor_failure?
      end

      test "serious_failure? returns true for outcome 8" do
        assert AuditEvent.new(outcome: "8").serious_failure?
      end

      test "major_failure? returns true for outcome 12" do
        assert AuditEvent.new(outcome: "12").major_failure?
      end

      test "outcome_display returns human-readable outcome" do
        assert_equal "Success", AuditEvent.new(outcome: "0").outcome_display
        assert_equal "Serious Failure", AuditEvent.new(outcome: "8").outcome_display
      end

      # =============================================================================
      # ENTITY HELPER TESTS
      # =============================================================================

      test "has_entity? returns true when entity is present" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "12345"
        )
        assert event.has_entity?
      end

      test "has_entity? returns false when entity is not present" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient"
        )
        refute event.has_entity?
      end

      # =============================================================================
      # FHIR SERIALIZATION TESTS
      # =============================================================================

      test "to_fhir returns valid FHIR AuditEvent resource" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Practitioner", agent_who_identifier: "101"
        )
        fhir = event.to_fhir
        assert_equal "AuditEvent", fhir[:resourceType]
        assert fhir[:id].present?
      end

      test "to_fhir includes type" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", agent_who_identifier: "101"
        )
        fhir = event.to_fhir
        assert_equal "rest", fhir.dig(:type, :code)
      end

      test "to_fhir includes action" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", agent_who_identifier: "101"
        )
        fhir = event.to_fhir
        assert_equal "R", fhir[:action]
      end

      test "to_fhir includes outcome" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", agent_who_identifier: "101"
        )
        fhir = event.to_fhir
        assert_equal "0", fhir[:outcome]
      end

      test "to_fhir includes recorded timestamp" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Practitioner", agent_who_identifier: "101"
        )
        fhir = event.to_fhir
        assert fhir[:recorded].present?
      end

      test "to_fhir includes agent" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient",
          agent_who_type: "Practitioner", agent_who_identifier: "101"
        )
        fhir = event.to_fhir
        assert fhir[:agent]&.any?
        agent = fhir[:agent].first
        assert agent.dig(:who, :reference)&.include?("Practitioner/101")
      end

      test "to_fhir includes entity when present" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "12345",
          agent_who_identifier: "101"
        )
        fhir = event.to_fhir
        assert fhir[:entity]&.any?
        entity = fhir[:entity].first
        assert entity.dig(:what, :reference)&.include?("Patient/12345")
      end

      test "to_fhir entity is empty when no entity_identifier" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient",
          agent_who_identifier: "101"
        )
        fhir = event.to_fhir
        assert_empty(fhir[:entity] || [])
      end

      test "to_fhir agent is empty when no agent_who_identifier" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient"
        )
        fhir = event.to_fhir
        assert_empty(fhir[:agent] || [])
      end

      test "to_fhir includes agent network address" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient",
          agent_who_type: "Practitioner", agent_who_identifier: "101",
          agent_network_address: "192.168.1.100"
        )
        fhir = event.to_fhir
        agent = fhir[:agent].first
        assert_equal "192.168.1.100", agent.dig(:network, :address)
      end

      test "to_fhir agent network is nil when no address" do
        event = AuditEvent.new(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient",
          agent_who_type: "Practitioner", agent_who_identifier: "101",
          agent_network_address: nil
        )
        fhir = event.to_fhir
        agent = fhir[:agent].first
        assert_nil agent[:network]
      end

      # =============================================================================
      # RESOURCE CLASS
      # =============================================================================

      test "resource_class returns AuditEvent" do
        assert_equal "AuditEvent", AuditEvent.resource_class
      end

      # =============================================================================
      # FROM_FHIR_ATTRIBUTES
      # =============================================================================

      test "from_fhir_attributes extracts attributes" do
        fhir_resource = OpenStruct.new(
          type: OpenStruct.new(code: "rest"),
          action: "R",
          outcome: "0"
        )

        attrs = AuditEvent.from_fhir_attributes(fhir_resource)
        assert_equal "rest", attrs[:event_type]
        assert_equal "R", attrs[:action]
        assert_equal "0", attrs[:outcome]
      end
    end
  end
end
