# frozen_string_literal: true

# Backend Services JWT Authentication step definitions — lakeraven-ehr
# ONC 170.315(g)(10)(vi)
#
# Reuses "the response status should be {int}" from bulk_export_steps.rb.

Given("a SMART backend service application is registered") do
  # Registered WITH a published JWKS, and the key that signs this client's
  # assertions is the one that JWKS serves. Previously this step registered a
  # client with no jwks_uri and the "valid assertion" step below forged the
  # signature with the literal string "test-signature" — which the endpoint
  # accepted, so this scenario asserted the bypass was working. A conformance
  # test that mints a credential without verifying anything certifies nothing.
  @backend_key = OpenSSL::PKey::RSA.new(2048)
  @backend_jwk = JWT::JWK.new(@backend_key)
  @backend_app = Doorkeeper::Application.create!(
    name: "Backend Service App",
    uid: "backend-service-client",
    redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
    scopes: "system/*.read",
    confidential: true,
    jwks_uri: "https://backend-client.example.test/.well-known/jwks.json",
    # A system credential must name the one organization it may read. An
    # unbound system token would otherwise be a read of every organization.
    organization_id: "rpms-organization-101"
  )
  stub_gateway(Lakeraven::EHR::ClientJwks, :fetch, { keys: [ @backend_jwk.export ] })
end

When("I POST to {string} with a valid client_credentials JWT assertion") do |path|
  # A genuinely valid assertion: RS256, signed by the client's published key,
  # audience = the token endpoint it is presented to.
  url = path.sub("/oauth/", "/lakeraven-ehr/oauth/")
  claims = {
    iss: @backend_app.uid,
    sub: @backend_app.uid,
    aud: "http://example.org/lakeraven-ehr/oauth/token",
    exp: 4.minutes.from_now.to_i,
    jti: SecureRandom.uuid
  }
  jwt_assertion = JWT.encode(claims, @backend_key, "RS256", kid: @backend_jwk[:kid])

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

# --- Scenarios carried over from #535 -------------------------------------
#
# These pin behaviours the JWKS work must not regress: a forged signature is
# refused, a scope the client is not registered for is never granted, and a
# token cannot reach an export the granted scope does not cover.

def backend_claims(overrides = {})
  {
    iss: @backend_app.uid,
    sub: @backend_app.uid,
    aud: "http://example.org/lakeraven-ehr/oauth/token",
    exp: 4.minutes.from_now.to_i,
    jti: SecureRandom.uuid
  }.merge(overrides)
end

def post_backend_token(assertion, scope:)
  post "/lakeraven-ehr/oauth/token", {
    grant_type: "client_credentials",
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    client_assertion: assertion,
    scope: scope
  }
  @response_json = JSON.parse(last_response.body) rescue nil
end

When("I POST to {string} with a forged-signature client_credentials JWT assertion") do |_path|
  # Signed by a key the client never published. Every claim is correct, so the
  # refusal must come from verification rather than a claim check standing in
  # for it.
  other_key = OpenSSL::PKey::RSA.new(2048)
  post_backend_token(
    JWT.encode(backend_claims, other_key, "RS256", kid: @backend_jwk[:kid]),
    scope: "system/*.read"
  )
end

When("I POST to {string} with a client_credentials JWT assertion requesting scope {string}") do |_path, scope|
  post_backend_token(
    JWT.encode(backend_claims, @backend_key, "RS256", kid: @backend_jwk[:kid]),
    scope: scope
  )
end

Then("the issued access token scopes should not include {string}") do |scope|
  issued = Doorkeeper::AccessToken.order(:created_at).last
  granted = issued ? issued.scopes.to_s.split : []
  expect(granted).not_to include(scope)
end

When("I POST to {string} with the issued access token") do |path|
  token = @response_json && @response_json["access_token"]
  post path, {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  @response_json = JSON.parse(last_response.body) rescue nil
end
