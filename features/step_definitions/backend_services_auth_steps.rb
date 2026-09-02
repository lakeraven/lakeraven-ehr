# frozen_string_literal: true

# Backend Services JWT Authentication step definitions — lakeraven-ehr
# ONC 170.315(g)(10)(vi)
#
# Reuses "the response status should be {int}" from bulk_export_steps.rb.

Given("a SMART backend service application is registered") do
  # Registers a client with a published JWKS; assertions are signed with the
  # matching private key (helpers in vardana_backend_services_auth_steps.rb).
  vardana_register_client(name: "Backend Service App", scopes: "system/*.read")
end

When("I POST to {string} with a valid client_credentials JWT assertion") do |path|
  url = path.sub("/oauth/", "/lakeraven-ehr/oauth/")
  post url, {
    grant_type: "client_credentials",
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    client_assertion: vardana_assertion,
    scope: "system/*.read"
  }
  @response_json = JSON.parse(last_response.body) rescue nil
end

When("I POST to {string} with client_credentials but no client_assertion") do |path|
  url = path.sub("/oauth/", "/lakeraven-ehr/oauth/")
  post url, {
    grant_type: "client_credentials",
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  }
  @response_json = JSON.parse(last_response.body) rescue nil
end

When("I POST to {string} with an invalid JWT assertion") do |path|
  url = path.sub("/oauth/", "/lakeraven-ehr/oauth/")
  post url, {
    grant_type: "client_credentials",
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    client_assertion: "not.a.valid.jwt"
  }
  @response_json = JSON.parse(last_response.body) rescue nil
end

Then("the response JSON should include {string}") do |key|
  refute_nil @response_json, "Expected JSON response"
  assert @response_json.key?(key), "Expected response JSON to include key '#{key}', keys: #{@response_json.keys}"
end

Then("the response JSON should include error {string}") do |error_value|
  refute_nil @response_json, "Expected JSON response"
  assert_equal error_value, @response_json["error"],
    "Expected error '#{error_value}', got '#{@response_json['error']}'"
end
