# frozen_string_literal: true

# SMART EHR Launch step definitions — lakeraven-ehr
# ONC 170.315(g)(10)(iii)
#
# "the response JSON should include {string}" is in backend_services_auth_steps.rb
# "the response JSON should include error {string}" is in backend_services_auth_steps.rb
# "the response status should be {int}" is in bulk_export_steps.rb

When("I request GET {string} without authentication") do |path|
  url = path.sub("/smart/", "/lakeraven-ehr/smart/")
  get url
  @response_json = JSON.parse(last_response.body) rescue nil
end

Given("a SMART application is registered with client_id {string}") do |client_id|
  @smart_app = Doorkeeper::Application.create!(
    name: "SMART Test App",
    uid: client_id,
    redirect_uri: "https://example.com/callback",
    scopes: "launch patient/*.read",
    confidential: false
  )
end

Then("the response should redirect to the authorize endpoint") do
  location = last_response.headers["Location"] || ""
  assert location.include?("authorize") || location.include?("oauth"),
    "Expected redirect to authorize endpoint, got Location: #{location}"
end
