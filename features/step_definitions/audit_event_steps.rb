# frozen_string_literal: true

# AuditEvent step definitions (model-level, no database)

def build_audit_event(attrs = {})
  defaults = {
    event_type: "rest", action: "R", outcome: "0",
    entity_type: "Patient", entity_identifier: "100"
  }
  # Build without saving — use allocate + assign to bypass AR validations requiring DB
  event = Lakeraven::EHR::AuditEvent.new(defaults.merge(attrs))
  event
end

Given("an audit event with action {string} for entity {string} {string}") do |action, entity_type, entity_id|
  @audit_event = build_audit_event(action: action, entity_type: entity_type, entity_identifier: entity_id)
end

Given("an audit event with outcome {string} for entity {string} {string}") do |outcome, entity_type, entity_id|
  @audit_event = build_audit_event(outcome: outcome, entity_type: entity_type, entity_identifier: entity_id)
end

Given("a rest audit event with action {string} for entity {string} {string}") do |action, entity_type, entity_id|
  @audit_event = build_audit_event(event_type: "rest", action: action, entity_type: entity_type, entity_identifier: entity_id)
end

Given("a security audit event with action {string} for entity {string} {string}") do |action, entity_type, entity_id|
  @audit_event = build_audit_event(event_type: "security", action: action, entity_type: entity_type, entity_identifier: entity_id)
end

Given("an export audit event with action {string} for entity {string} {string}") do |action, entity_type, entity_id|
  @audit_event = build_audit_event(event_type: "export", action: action, entity_type: entity_type, entity_identifier: entity_id)
end

Given("an import audit event with action {string} for entity {string} {string}") do |action, entity_type, entity_id|
  @audit_event = build_audit_event(event_type: "import", action: action, entity_type: entity_type, entity_identifier: entity_id)
end

Given("a query audit event with action {string} for entity {string} {string}") do |action, entity_type, entity_id|
  @audit_event = build_audit_event(event_type: "query", action: action, entity_type: entity_type, entity_identifier: entity_id)
end

Given("a user audit event with action {string} for entity {string} {string}") do |action, entity_type, entity_id|
  @audit_event = build_audit_event(event_type: "user", action: action, entity_type: entity_type, entity_identifier: entity_id)
end

Given("an application audit event with action {string} for entity {string} {string}") do |action, entity_type, entity_id|
  @audit_event = build_audit_event(event_type: "application", action: action, entity_type: entity_type, entity_identifier: entity_id)
end

Given("an audit event with action {string} and entity type {string} but no identifier") do |action, entity_type|
  @audit_event = build_audit_event(action: action, entity_type: entity_type, entity_identifier: nil)
end

Given("an audit event with action {string} for entity {string} {string} by agent {string}") do |action, entity_type, entity_id, agent_id|
  @audit_event = build_audit_event(
    action: action, entity_type: entity_type, entity_identifier: entity_id,
    agent_who_identifier: agent_id, agent_who_type: "Practitioner", agent_name: "Dr. Test"
  )
end

Given("an audit event with outcome {string} and description {string} for entity {string} {string}") do |outcome, desc, entity_type, entity_id|
  @audit_event = build_audit_event(
    outcome: outcome, outcome_desc: desc, entity_type: entity_type, entity_identifier: entity_id
  )
end

Given("an audit event with action {string} for entity {string} {string} by agent {string} from {string}") do |action, entity_type, entity_id, agent_id, ip|
  @audit_event = build_audit_event(
    action: action, entity_type: entity_type, entity_identifier: entity_id,
    agent_who_identifier: agent_id, agent_who_type: "Practitioner",
    agent_name: "Dr. Test", agent_network_address: ip
  )
end

When("I serialize the audit event to FHIR") do
  @fhir = @audit_event.to_fhir
end

# Action helpers
Then("the audit event should be a read action") do
  assert @audit_event.read_action?
end

Then("the audit event should be a create action") do
  assert @audit_event.create_action?
end

Then("the audit event should be an update action") do
  assert @audit_event.update_action?
end

Then("the audit event should be a delete action") do
  assert @audit_event.delete_action?
end

Then("the audit event should be an execute action") do
  assert @audit_event.execute_action?
end

Then("the audit event action display should be {string}") do |expected|
  assert_equal expected, @audit_event.action_display
end

# Outcome helpers
Then("the audit event should be successful") do
  assert @audit_event.success?
end

Then("the audit event should be a minor failure") do
  assert @audit_event.minor_failure?
end

Then("the audit event should be a serious failure") do
  assert @audit_event.serious_failure?
end

Then("the audit event should be a major failure") do
  assert @audit_event.major_failure?
end

Then("the audit event outcome display should be {string}") do |expected|
  assert_equal expected, @audit_event.outcome_display
end

# Event type helpers
Then("the audit event type display should be {string}") do |expected|
  assert_equal expected, @audit_event.event_type_display
end

# Entity helpers
Then("the audit event should have an entity") do
  assert @audit_event.has_entity?
end

Then("the audit event should not have an entity") do
  refute @audit_event.has_entity?
end

# FHIR assertions
Then("the FHIR audit event action should be {string}") do |expected|
  assert_equal expected, @fhir[:action]
end

Then("the FHIR audit event outcome should be {string}") do |expected|
  assert_equal expected, @fhir[:outcome]
end

Then("the FHIR audit event entity should reference {string}") do |expected|
  entities = @fhir[:entity]
  refute_nil entities
  assert entities.any? { |e| e[:what][:reference] == expected }
end

Then("the FHIR audit event agent should include {string}") do |agent_id|
  agents = @fhir[:agent]
  refute_nil agents
  assert agents.any? { |a| a[:who][:reference]&.include?(agent_id) }
end

Then("the FHIR audit event type code should be {string}") do |expected|
  assert_equal expected, @fhir[:type][:code]
end

Then("the FHIR audit event outcome description should be {string}") do |expected|
  assert_equal expected, @fhir[:outcomeDesc]
end

Then("the FHIR audit event agent network should be {string}") do |expected|
  agents = @fhir[:agent]
  refute_nil agents
  assert agents.any? { |a| a.dig(:network, :address) == expected }
end

Then("the FHIR audit event agents should be empty") do
  agents = @fhir[:agent]
  assert agents.nil? || agents.empty?
end

Then("the FHIR audit event entities should be empty") do
  entities = @fhir[:entity]
  assert entities.nil? || entities.empty?
end
