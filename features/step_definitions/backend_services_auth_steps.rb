# frozen_string_literal: true

# Backend Services JWT Authentication step definitions — lakeraven-ehr
# ONC 170.315(g)(10)(vi)
#
# Reuses "the response status should be {int}" from bulk_export_steps.rb.

# A registered backend service has a registered PUBLIC KEY — without one there
# is nothing to verify its assertions against, and the endpoint refuses it.
Given("a SMART backend service application is registered") do
  @client_key = OpenSSL::PKey::RSA.generate(2048)
  @backend_app = Doorkeeper::Application.create!(
    name: "Backend Service App",
    uid: "backend-service-client",
    redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
    scopes: "system/*.read",
    confidential: true,
    public_key: @client_key.public_key.to_pem
  )
end

# Builds a genuinely signed assertion for the registered client, so a scenario
# that is meant to fail elsewhere is not merely failing at the signature.
def signed_backend_assertion(key:, aud:, overrides: {}, signature: nil)
  header_b64 = Base64.urlsafe_encode64({ alg: "RS384", typ: "JWT" }.to_json, padding: false)
  payload = {
    iss: "backend-service-client",
    sub: "backend-service-client",
    aud: aud,
    exp: 5.minutes.from_now.to_i,
    jti: SecureRandom.uuid
  }.merge(overrides)
  payload_b64 = Base64.urlsafe_encode64(payload.to_json, padding: false)
  signing_input = "#{header_b64}.#{payload_b64}"
  sig_b64 = signature || Base64.urlsafe_encode64(
    key.sign(OpenSSL::Digest.new("SHA384"), signing_input), padding: false
  )
  "#{signing_input}.#{sig_b64}"
end

# Must equal what the controller computes with url_for, which is built from
# the request host. Rack::Test defaults to example.org.
def backend_token_aud
  "http://example.org/lakeraven-ehr/oauth/token"
end

When("I POST to {string} with a valid client_credentials JWT assertion") do |path|
  jwt_assertion = signed_backend_assertion(key: @client_key, aud: backend_token_aud)

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

When("I POST to {string} with a forged-signature client_credentials JWT assertion") do |path|
  # Every claim is correct; only the signature is not. The refusal must come
  # from verification, not from a claim check standing in for it.
  jwt_assertion = signed_backend_assertion(
    key: @client_key, aud: backend_token_aud, signature: "not-a-signature"
  )

  url = path.sub("/oauth/", "/lakeraven-ehr/oauth/")
  post url, {
    grant_type: "client_credentials",
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    client_assertion: jwt_assertion,
    scope: "system/*.read"
  }
  @response_json = JSON.parse(last_response.body) rescue nil
end

When("I POST to {string} with a client_credentials JWT assertion requesting scope {string}") do |path, scope|
  jwt_assertion = signed_backend_assertion(key: @client_key, aud: backend_token_aud)

  url = path.sub("/oauth/", "/lakeraven-ehr/oauth/")
  post url, {
    grant_type: "client_credentials",
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    client_assertion: jwt_assertion,
    scope: scope
  }
  @response_json = JSON.parse(last_response.body) rescue nil
end

When("I POST to {string} with the issued access token") do |path|
  token = @response_json && @response_json["access_token"]
  header "Authorization", "Bearer #{token}"
  post path
end

Then("the issued access token scopes should not include {string}") do |scope|
  refute_nil @response_json, "Expected JSON response"
  granted = @response_json["scope"].to_s.split
  refute_includes granted, scope, "Scope '#{scope}' was granted: #{@response_json['scope'].inspect}"
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
