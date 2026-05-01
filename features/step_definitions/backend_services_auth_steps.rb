# frozen_string_literal: true

# Backend Services JWT Authentication step definitions — lakeraven-ehr
# ONC 170.315(g)(10)(vi)
#
# Reuses "the response status should be {int}" from bulk_export_steps.rb.

Given("a SMART backend service application is registered") do
  @backend_app = Doorkeeper::Application.create!(
    name: "Backend Service App",
    uid: "backend-service-client",
    redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
    scopes: "system/*.read",
    confidential: true
  )
end

When("I POST to {string} with a valid client_credentials JWT assertion") do |path|
  # Build a minimal JWT (header.payload.signature) with iss = client_id
  header_b64 = Base64.urlsafe_encode64({ alg: "HS256", typ: "JWT" }.to_json, padding: false)
  payload = {
    iss: "backend-service-client",
    sub: "backend-service-client",
    aud: "http://example.org/oauth/token",
    exp: 5.minutes.from_now.to_i,
    jti: SecureRandom.uuid
  }
  payload_b64 = Base64.urlsafe_encode64(payload.to_json, padding: false)
  sig_b64 = Base64.urlsafe_encode64("test-signature", padding: false)
  jwt_assertion = "#{header_b64}.#{payload_b64}.#{sig_b64}"

  url = path.sub("/oauth/", "/lakeraven-ehr/oauth/")
  post url, {
    grant_type: "client_credentials",
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    client_assertion: jwt_assertion,
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
