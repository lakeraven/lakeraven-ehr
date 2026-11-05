# frozen_string_literal: true

# SMART EHR Launch step definitions — lakeraven-ehr
# ONC 170.315(g)(10)(iii)
#
# "the response JSON should include {string}" is in backend_services_auth_steps.rb
# "the response status should be {int}" is in bulk_export_steps.rb

When("I request GET {string} without authentication") do |path|
  url = path.sub("/smart/", "/lakeraven-ehr/smart/")
  get url
  @response_json = JSON.parse(last_response.body) rescue nil
end

Then("the response should redirect to the sign-in page") do
  assert_equal 302, last_response.status
  assert last_response.headers["Location"].to_s.end_with?("/lakeraven-ehr/login"),
    "Expected a redirect to sign in, got Location: #{last_response.headers['Location']}"
end
