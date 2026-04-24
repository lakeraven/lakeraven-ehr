# frozen_string_literal: true

# FHIR Clinical Resource Steps — lakeraven-ehr
# Exercises FHIR R4 API endpoints per ONC § 170.315(g)(10)
#
# Reuses shared steps from bulk_export_steps.rb (response status)
# and cqm_steps.rb (FHIR Bundle). Only defines steps unique to this feature.

Given("I am authenticated with SMART-on-FHIR") do
  @fhir_headers = {
    "Accept" => "application/fhir+json",
    "Content-Type" => "application/fhir+json"
  }

  @oauth_app ||= Doorkeeper::Application.create!(
    name: "Cucumber FHIR Test",
    redirect_uri: "https://example.com/callback"
  )
  @smart_token = Doorkeeper::AccessToken.create!(
    application: @oauth_app,
    resource_owner_id: 1,
    scopes: "patient/*.read user/*.read launch openid profile",
    expires_in: 3600
  )
  @fhir_headers["Authorization"] = "Bearer #{@smart_token.token}"
end

Given("patient {string} has clinical data in the system") do |dfn|
  patient = Lakeraven::EHR::Patient.find_by_dfn(dfn.to_i)
  assert patient, "Expected patient DFN #{dfn} to exist in mock seeds"
end

When("I request GET {string}") do |path|
  @fhir_headers.each { |k, v| header k, v }
  get path
end

When("I request GET {string} with params:") do |path, table|
  @fhir_headers.each { |k, v| header k, v }
  params = table.rows_hash
  get "#{path}?#{URI.encode_www_form(params)}"
end

# Helper to parse response JSON (used by steps below)
def parsed_response
  @_parsed_response = JSON.parse(last_response.body) rescue nil
end

Then("the response should be valid FHIR JSON") do
  assert_includes last_response.content_type, "json", "Expected JSON content type"
  refute_nil parsed_response, "Expected response body to be valid JSON"
  assert parsed_response["resourceType"], "Expected resourceType in response"
end

Then("the response resourceType should be {string}") do |resource_type|
  assert_equal resource_type, parsed_response["resourceType"]
end

Then("the Bundle should have type {string}") do |bundle_type|
  assert_equal bundle_type, parsed_response["type"]
end

Then("each entry should have resourceType {string}") do |resource_type|
  entries = parsed_response["entry"] || []
  entries.each do |entry|
    assert_equal resource_type, entry.dig("resource", "resourceType")
  end
end

Then("the response content type should include {string}") do |content_type|
  assert_includes last_response.content_type, content_type,
    "Expected content type to include '#{content_type}', got '#{last_response.content_type}'"
end
