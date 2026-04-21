# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AuditEventTest < ActiveSupport::TestCase
      teardown do
        AuditEvent.delete_all
      end

      test "creates an audit event with required fields" do
        event = AuditEvent.create!(
          event_type: "rest",
          action: "R",
          outcome: "0",
          entity_type: "Patient",
          entity_identifier: "1",
          agent_who_type: "Application",
          agent_who_identifier: "test-app"
        )

        assert event.persisted?
        assert_equal "rest", event.event_type
        assert_equal "R", event.action
        assert_equal "0", event.outcome
      end

      test "audit rows are immutable" do
        event = AuditEvent.create!(
          event_type: "rest", action: "R", outcome: "0",
          entity_type: "Patient", entity_identifier: "1",
          agent_who_type: "Application", agent_who_identifier: "test-app"
        )

        assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(outcome: "4") }
      end

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
