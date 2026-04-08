# frozen_string_literal: true

require "active_support/testing/time_helpers"

Given('the host mints a launch context for patient {string}') do |display_name|
  tenant = Lakeraven::EHR::Current.tenant_identifier
  patient = Lakeraven::EHR.adapter.search_patients(tenant_identifier: tenant, name: display_name).first
  raise "no patient with display_name #{display_name}" unless patient

  @launch_context = Lakeraven::EHR::LaunchContext.mint(
    tenant_identifier: tenant,
    oauth_application_uid: @oauth_app.uid,
    patient_identifier: patient[:patient_identifier],
    facility_identifier: Lakeraven::EHR::Current.facility_identifier
  )
end

Given('the host mints a launch context for patient {string} that expires in {int} minute(s)') do |display_name, minutes|
  tenant = Lakeraven::EHR::Current.tenant_identifier
  patient = Lakeraven::EHR.adapter.search_patients(tenant_identifier: tenant, name: display_name).first
  raise "no patient with display_name #{display_name}" unless patient

  @launch_context = Lakeraven::EHR::LaunchContext.mint(
    tenant_identifier: tenant,
    oauth_application_uid: @oauth_app.uid,
    patient_identifier: patient[:patient_identifier],
    ttl: minutes.minutes
  )
end

Given('{int} minutes pass') do |minutes|
  travel(minutes.minutes)
end

Then('the launch context has a launch_token starting with {string}') do |prefix|
  assert @launch_context.launch_token.start_with?(prefix),
    "expected launch_token to start with #{prefix}, got #{@launch_context.launch_token}"
end

Then('the launch context binds the tenant {string}') do |tenant_identifier|
  assert_equal tenant_identifier, @launch_context.tenant_identifier
end

When('I POST to the OAuth token endpoint with grant_type {string} and the launch token') do |grant_type|
  post "/lakeraven-ehr/oauth/token", {
    grant_type: grant_type,
    client_id: @oauth_app.uid,
    client_secret: @client_secret,
    scope: @oauth_app.scopes.to_s,
    launch: @launch_context.launch_token
  }, { "HTTP_X_TENANT_IDENTIFIER" => Lakeraven::EHR::Current.tenant_identifier || "tnt_test" }
end

When('I POST to the OAuth token endpoint with grant_type {string} and an unknown launch token') do |grant_type|
  post "/lakeraven-ehr/oauth/token", {
    grant_type: grant_type,
    client_id: @oauth_app.uid,
    client_secret: @client_secret,
    scope: @oauth_app.scopes.to_s,
    launch: "lc_does_not_exist"
  }, { "HTTP_X_TENANT_IDENTIFIER" => Lakeraven::EHR::Current.tenant_identifier || "tnt_test" }
end

Then("the response body has no patient field") do
  body = parsed_body
  refute body.key?("patient"), "expected no patient field, got #{body.inspect}"
end

Then("the response body patient field equals the bound patient_identifier") do
  assert_equal @launch_context.patient_identifier, parsed_body["patient"]
end

# travel/travel_to are ActiveSupport::Testing::TimeHelpers methods. Bring
# them into the cucumber world so the launch-token expiration scenarios
# can advance the clock.
World(ActiveSupport::Testing::TimeHelpers)

After do
  travel_back if Time.respond_to?(:current) && respond_to?(:travel_back)
end
