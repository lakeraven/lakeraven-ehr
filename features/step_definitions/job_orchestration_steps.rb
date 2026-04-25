# frozen_string_literal: true

require "active_job"

# Job Orchestration Steps — lakeraven-ehr

Given("an auditable job that succeeds") do
  unless Object.const_defined?(:EhrSuccessTestJob)
    Object.const_set(:EhrSuccessTestJob, Class.new(ActiveJob::Base) {
      include Lakeraven::EHR::Auditable
      self.queue_adapter = :inline

      def perform
        "success"
      end
    })
  end
  @job_class = EhrSuccessTestJob
end

Given("an auditable job that raises {string}") do |error_message|
  @expected_error_message = error_message
  const_name = "EhrFailJob#{error_message.hash.abs}"
  unless Object.const_defined?(const_name)
    klass = Class.new(ActiveJob::Base) {
      include Lakeraven::EHR::Auditable
      self.queue_adapter = :inline

      define_method(:perform) do
        raise StandardError, error_message
      end
    }
    Object.const_set(const_name, klass)
  end
  @job_class = Object.const_get(const_name)
end

When("the job is performed") do
  Lakeraven::EHR::AuditEvent.delete_all
  @job_class.perform_now
end

When("the job is performed and fails") do
  Lakeraven::EHR::AuditEvent.delete_all
  @job_class.perform_now rescue nil
end

Then("an audit event should exist with outcome {string} and entity type {string}") do |outcome, entity_type|
  @audit_event = Lakeraven::EHR::AuditEvent.find_by(outcome: outcome, entity_type: entity_type)
  assert @audit_event, "Expected AuditEvent with outcome=#{outcome}, entity_type=#{entity_type}"
end

Then("the audit event action should be {string}") do |action|
  assert_equal action, @audit_event.action
end

Then("the audit event type should be {string}") do |event_type|
  assert_equal event_type, @audit_event.event_type
end

Then("the failure audit event should have a sanitized outcome description") do
  event = Lakeraven::EHR::AuditEvent.find_by(outcome: "8", entity_type: "Job")
  assert event, "Expected failure AuditEvent"
  assert event.outcome_desc.present?, "Expected outcome_desc to be present"
  refute_includes event.outcome_desc, "12345"
end

Then("the failure outcome description should not contain {string}") do |phi_text|
  event = Lakeraven::EHR::AuditEvent.find_by(outcome: "8", entity_type: "Job")
  assert event, "Expected failure AuditEvent"
  refute_includes event.outcome_desc, phi_text
end

Then("the most recent audit event should have action {string}") do |action|
  event = Lakeraven::EHR::AuditEvent.order(created_at: :desc).first
  assert event, "Expected at least one AuditEvent"
  assert_equal action, event.action
end

Then("the most recent audit event should have a network address") do
  event = Lakeraven::EHR::AuditEvent.order(created_at: :desc).first
  assert event, "Expected at least one AuditEvent"
  assert event.agent_network_address.present?, "Expected network address"
end
