# frozen_string_literal: true

Then("a Patient-read AuditEvent row exists for the last request") do
  event = Lakeraven::EHR::AuditEvent.recent.first
  refute_nil event, "expected an AuditEvent row, found none"
  assert_equal "rest", event.event_type
  assert_equal "R", event.action
  assert_equal "Patient", event.entity_type
end

Then('the last AuditEvent row has entity_type {string}') do |entity_type|
  event = Lakeraven::EHR::AuditEvent.recent.first
  assert_equal entity_type, event.entity_type
end

Then('the last AuditEvent row has an opaque entity_identifier prefixed with {string}') do |prefix|
  event = Lakeraven::EHR::AuditEvent.recent.first
  assert event.entity_identifier.to_s.start_with?(prefix),
    "expected entity_identifier to start with #{prefix}, got #{event.entity_identifier}"
end

Then("the last AuditEvent row has no display_name or date_of_birth column") do
  columns = Lakeraven::EHR::AuditEvent.column_names
  refute_includes columns, "display_name"
  refute_includes columns, "date_of_birth"
end

Then('the last AuditEvent row has outcome {string}') do |outcome|
  event = Lakeraven::EHR::AuditEvent.recent.first
  assert_equal outcome, event.outcome
end

Then("updating the last AuditEvent row raises a ReadOnly error") do
  event = Lakeraven::EHR::AuditEvent.recent.first
  assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(outcome: "4") }
end

Then("deleting the last AuditEvent row raises a ReadOnly error") do
  event = Lakeraven::EHR::AuditEvent.recent.first
  assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
end

Given('{int} AuditEvent row(s) exist(s) in the current tenant') do |count|
  count.times do
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      tenant_identifier: Lakeraven::EHR::Current.tenant_identifier,
      facility_identifier: Lakeraven::EHR::Current.facility_identifier,
      agent_who_type: "Application", agent_who_identifier: @oauth_app.uid,
      entity_type: "Patient", entity_identifier: "pt_#{SecureRandom.hex(4)}"
    )
  end
end

Given('{int} AuditEvent row(s) exist(s) in another tenant') do |count|
  count.times do
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      tenant_identifier: "tnt_other", facility_identifier: "fac_main",
      agent_who_type: "Application", agent_who_identifier: "other-client",
      entity_type: "Patient", entity_identifier: "pt_foreign"
    )
  end
end

When("I GET the FHIR AuditEvent endpoint with a valid token") do
  @audit_scope_token ||= Doorkeeper::AccessToken.create!(
    application: @oauth_app, scopes: "system/AuditEvent.read", expires_in: 3600
  )
  plaintext = @audit_scope_token.plaintext_token || @audit_scope_token.token
  @parsed_body = nil
  get "/lakeraven-ehr/AuditEvent", {}, {
    "HTTP_AUTHORIZATION" => "Bearer #{plaintext}",
    "HTTP_X_TENANT_IDENTIFIER" => Lakeraven::EHR::Current.tenant_identifier
  }
end

When("I GET the FHIR AuditEvent endpoint without a Bearer token") do
  @parsed_body = nil
  get "/lakeraven-ehr/AuditEvent", {}, {
    "HTTP_X_TENANT_IDENTIFIER" => Lakeraven::EHR::Current.tenant_identifier
  }
end

When('I GET the FHIR AuditEvent endpoint with a token that only has {string} scope') do |scope|
  wrong_scope_token = Doorkeeper::AccessToken.create!(
    application: @oauth_app, scopes: scope, expires_in: 3600
  )
  plaintext = wrong_scope_token.plaintext_token || wrong_scope_token.token
  @parsed_body = nil
  get "/lakeraven-ehr/AuditEvent", {}, {
    "HTTP_AUTHORIZATION" => "Bearer #{plaintext}",
    "HTTP_X_TENANT_IDENTIFIER" => Lakeraven::EHR::Current.tenant_identifier
  }
end

Then('the response body is a FHIR Bundle of type {string}') do |bundle_type|
  assert_equal "Bundle", parsed_body["resourceType"]
  assert_equal bundle_type, parsed_body["type"]
end

Then('the Bundle total is {int}') do |total|
  assert_equal total, parsed_body["total"]
end

Then("no entry in the Bundle belongs to another tenant") do
  # Cross-tenant rows use entity_identifier "pt_foreign". They must
  # not appear in the response — the controller scopes to
  # Current.tenant_identifier.
  entity_ids = parsed_body["entry"].map { |e|
    e.dig("resource", "entity")&.first&.dig("what", "identifier", "value")
  }
  refute_includes entity_ids, "pt_foreign"
end
