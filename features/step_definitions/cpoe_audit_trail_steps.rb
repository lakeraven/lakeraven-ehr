# frozen_string_literal: true

# CPOE audit trail step definitions
# AuditEvent stores audit subtypes in outcome_desc (e.g. "medication order created").
# The feature uses underscore keys; CpoeAuditor writes space-separated descriptions.
# "lab" in feature maps to "laboratory" in CpoeAuditor.

SUBTYPE_TO_DESC = {
  "medication_order_created" => "medication order created",
  "medication_order_signed" => "medication order signed",
  "medication_order_cancelled" => "medication order cancelled",
  "lab_order_created" => "laboratory order created",
  "lab_order_signed" => "laboratory order signed",
  "imaging_order_created" => "imaging order created",
  "imaging_order_signed" => "imaging order signed"
}.freeze

Then("an audit event should exist with subtype {string}") do |subtype|
  desc_pattern = SUBTYPE_TO_DESC.fetch(subtype, subtype.tr("_", " "))
  @audit_event = Lakeraven::EHR::AuditEvent
    .where("outcome_desc LIKE ?", "%#{desc_pattern}%")
    .order(created_at: :desc)
    .first
  assert @audit_event.present?,
    "Expected AuditEvent with outcome_desc matching '#{desc_pattern}'"
end

Then("the audit event agent should be {string}") do |agent_id|
  assert_equal agent_id, @audit_event.agent_who_identifier
end

Then("the audit event should include a content hash") do
  assert_match(/Content hash: [a-f0-9]+/, @audit_event.outcome_desc)
end

Then("the audit event should include reason {string}") do |reason|
  assert_match(/Reason: #{Regexp.escape(reason)}/, @audit_event.outcome_desc)
end

Then("the audit trail for the order should have {int} events") do |count|
  order_id = @order_result.order.respond_to?(:ien) ? @order_result.order.ien : @order_result.order.id
  @audit_trail = Lakeraven::EHR::CpoeAuditor.trail_for(order_id)
  assert_equal count, @audit_trail.count,
    "Expected #{count} audit events, got #{@audit_trail.count}: #{@audit_trail.map(&:outcome_desc).inspect}"
end

Then("the audit trail should show {string} then {string}") do |first_subtype, second_subtype|
  first_pattern = SUBTYPE_TO_DESC.fetch(first_subtype, first_subtype.tr("_", " "))
  second_pattern = SUBTYPE_TO_DESC.fetch(second_subtype, second_subtype.tr("_", " "))
  assert_match(/#{first_pattern}/, @audit_trail.first.outcome_desc)
  assert_match(/#{second_pattern}/, @audit_trail.second.outcome_desc)
end
