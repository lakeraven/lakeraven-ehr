# frozen_string_literal: true

# PHI Audit Logging Steps — lakeraven-ehr
# Verifies HIPAA § 164.312(b) audit logging via FHIR API access

Given("no audit events exist") do
  Lakeraven::EHR::AuditEvent.delete_all
end

Then("an audit event should exist with action {string} and entity type {string}") do |action, entity_type|
  event = Lakeraven::EHR::AuditEvent.find_by(action: action, entity_type: entity_type)
  assert event, "Expected AuditEvent with action=#{action}, entity_type=#{entity_type}. " \
                "Found: #{Lakeraven::EHR::AuditEvent.pluck(:action, :entity_type)}"
end

Then("an audit event should exist with outcome {string}") do |outcome|
  event = Lakeraven::EHR::AuditEvent.find_by(outcome: outcome)
  assert event, "Expected AuditEvent with outcome=#{outcome}. " \
                "Found: #{Lakeraven::EHR::AuditEvent.pluck(:outcome)}"
end

# Immutability

Given("an audit event exists in the database") do
  @audit_event = Lakeraven::EHR::AuditEvent.create!(
    event_type: "rest",
    action: "R",
    outcome: "0",
    agent_who_type: "Application",
    agent_who_identifier: "test-app",
    entity_type: "Patient",
    entity_identifier: "12345"
  )
end

When("I try to update the audit event") do
  @audit_event.outcome = "4"
  @audit_event.save
  @update_succeeded = !@audit_event.readonly?
rescue ActiveRecord::ReadOnlyRecord
  @update_succeeded = false
end

When("I try to delete the audit event") do
  @audit_event.destroy
  @delete_succeeded = !@audit_event.readonly?
rescue ActiveRecord::ReadOnlyRecord
  @delete_succeeded = false
end

Then("the update should be rejected as immutable") do
  refute @update_succeeded, "Expected update to be rejected"
end

Then("the deletion should be rejected as immutable") do
  refute @delete_succeeded, "Expected deletion to be rejected"
end

# Structure

Then("the most recent audit event should have event_type {string}") do |event_type|
  event = Lakeraven::EHR::AuditEvent.order(created_at: :desc).first
  assert event, "Expected at least one AuditEvent"
  assert_equal event_type, event.event_type
end

Then("the most recent audit event should have a recorded timestamp") do
  event = Lakeraven::EHR::AuditEvent.order(created_at: :desc).first
  assert event, "Expected at least one AuditEvent"
  assert event.created_at, "Expected audit event to have a timestamp"
end
