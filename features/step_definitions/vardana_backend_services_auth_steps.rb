# frozen_string_literal: true

# Vardana source-system auth conformance — SMART Backend Services steps.
#
# Checklist item 1: token obtained with a signed JWT assertion against a
# published JWKS (real RSA keypairs; the JWKS fetch is stubbed to the
# client's published key set).
# Checklist item 2: per-organization credential scoping — an org-bound
# credential must be denied another organization's patients.
#
# Reuses from other step files:
#   - "the response status should be {int}"                 (bulk_export_steps)
#   - "I request GET {string} with/without a Bearer token"  (bulk_export_steps)
#   - "the response should be a FHIR OperationOutcome ..."  (bulk_export_steps)
#   - "the response JSON should include (error) {string}"   (backend_services_auth_steps)

require "openssl"

module VardanaAuthWorld
  VARDANA_TOKEN_PATH = "/lakeraven-ehr/oauth/token"
  VARDANA_TOKEN_AUD = "http://example.org/lakeraven-ehr/oauth/token"
  VARDANA_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  # Registration defaults to an organization binding: the token endpoint
  # refuses to mint system/ tokens for unbound credentials (fail closed), so
  # only the explicit "no organization binding" scenario registers without one.
  def vardana_register_client(name:, scopes:, organization_id: "rpms-organization-101",
                              with_jwks: true, stub_fetch: true)
    @vardana_key = OpenSSL::PKey::RSA.new(2048)
    @vardana_jwk = JWT::JWK.new(@vardana_key)
    @vardana_app = Doorkeeper::Application.create!(
      name: name,
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: scopes,
      confidential: true,
      jwks_uri: with_jwks ? "https://client.example.test/.well-known/jwks.json" : nil,
      organization_id: organization_id
    )
    return unless with_jwks && stub_fetch

    stub_gateway(Lakeraven::EHR::ClientJwks, :fetch, { keys: [ @vardana_jwk.export ] })
  end

  # Substitute DNS resolution for JWKS transport scenarios (@webmock stubs the
  # HTTP layer; this stubs name resolution so the SSRF address checks run
  # against controlled answers).
  def vardana_stub_resolver(mapping)
    fake = Object.new
    fake.define_singleton_method(:getaddresses) { |host| Array(mapping[host]) }
    Lakeraven::EHR::ClientJwks.resolver = fake
  end

  def vardana_assertion(key: @vardana_key, kid: @vardana_jwk.kid,
                        exp: 4.minutes.from_now.to_i, aud: VARDANA_TOKEN_AUD,
                        jti: SecureRandom.uuid)
    claims = { iss: @vardana_app.uid, sub: @vardana_app.uid, aud: aud, exp: exp, jti: jti }
    JWT.encode(claims, key, "RS384", { kid: kid, typ: "JWT" })
  end

  def vardana_post_token(assertion, scope:)
    @vardana_last_assertion = assertion
    @vardana_last_scope = scope
    post VARDANA_TOKEN_PATH, {
      grant_type: "client_credentials",
      client_assertion_type: VARDANA_ASSERTION_TYPE,
      client_assertion: assertion,
      scope: scope
    }
    @response_json = begin
      JSON.parse(last_response.body)
    rescue JSON::ParserError
      nil
    end
  end

  def vardana_site_ien(org_id)
    org_id[/\d+\z/].to_i
  end

  def vardana_synthetic_patient(dfn:, name:, site_ien:)
    Lakeraven::EHR::Patient.new(
      dfn: dfn, name: name, sex: "M", dob: Date.new(1970, 1, 1),
      phone: "555-0100", site_ien: site_ien
    )
  end
end
World(VardanaAuthWorld)

# --- Registration -----------------------------------------------------------

Given("a backend client {string} is registered with a published JWKS and scopes {string}") do |name, scopes|
  vardana_register_client(name: name, scopes: scopes)
end

Given("a backend client {string} is registered without a JWKS and scopes {string}") do |name, scopes|
  vardana_register_client(name: name, scopes: scopes, with_jwks: false)
end

Given("a backend client {string} is registered with a published JWKS but no organization binding, with scopes {string}") do |name, scopes|
  vardana_register_client(name: name, scopes: scopes, organization_id: nil)
end

Given("the server is configured with token endpoint URL {string}") do |url|
  Lakeraven::EHR.configuration.token_endpoint_url = url
end

# The token is minted directly (not through the token endpoint, which
# refuses unbound clients) to model a credential that predates mandatory
# binding or whose binding was blanked after issuance.
Given("a backend client with no organization binding holds a directly minted token with scope {string}") do |scopes|
  app = Doorkeeper::Application.create!(
    name: "Example Unbound Connector",
    redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
    scopes: scopes, confidential: true, organization_id: nil
  )
  token = Doorkeeper::AccessToken.create!(application: app, scopes: scopes, expires_in: 300)
  @fhir_headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
end

Given("a backend client bound to organization {string} holds a token with scope {string}") do |org_id, scopes|
  vardana_register_client(name: "Example Connector #{org_id}", scopes: scopes, organization_id: org_id)
  token = Doorkeeper::AccessToken.create!(application: @vardana_app, scopes: scopes, expires_in: 300)
  @fhir_headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
end

# --- Token requests ---------------------------------------------------------

When("the client requests a token with a valid signed assertion and scope {string}") do |scope|
  vardana_post_token(vardana_assertion, scope: scope)
end

When("the client requests a token with an assertion signed by a different key") do
  rogue_key = OpenSSL::PKey::RSA.new(2048)
  vardana_post_token(vardana_assertion(key: rogue_key), scope: "system/Patient.read")
end

When("the client requests a token with an expired signed assertion") do
  vardana_post_token(vardana_assertion(exp: 2.minutes.ago.to_i), scope: "system/Patient.read")
end

When("the client requests a token with a signed assertion for audience {string}") do |aud|
  vardana_post_token(vardana_assertion(aud: aud), scope: "system/Patient.read")
end

When("the client replays the same assertion") do
  vardana_post_token(@vardana_last_assertion, scope: @vardana_last_scope)
end

When("the client requests a token with a signed assertion that has no exp claim") do
  claims = { iss: @vardana_app.uid, sub: @vardana_app.uid,
             aud: VardanaAuthWorld::VARDANA_TOKEN_AUD, jti: SecureRandom.uuid }
  assertion = JWT.encode(claims, @vardana_key, "RS384", { kid: @vardana_jwk.kid, typ: "JWT" })
  vardana_post_token(assertion, scope: "system/Patient.read")
end

When("the client requests a token with a signed assertion that expires {int} seconds from now") do |seconds|
  vardana_post_token(vardana_assertion(exp: seconds.seconds.from_now.to_i),
    scope: "system/Patient.read")
end

When("the client requests a token with an unsigned alg=none assertion") do
  claims = { iss: @vardana_app.uid, sub: @vardana_app.uid, aud: VardanaAuthWorld::VARDANA_TOKEN_AUD,
             exp: 4.minutes.from_now.to_i, jti: SecureRandom.uuid }
  vardana_post_token(JWT.encode(claims, nil, "none"), scope: "system/Patient.read")
end

# Algorithm-confusion probe: sign with HMAC using the published RSA public
# key PEM as the shared secret. A verifier that lets the token pick the
# algorithm would validate this against the same key material.
When("the client requests a token with an HMAC assertion keyed with the published RSA public key") do
  claims = { iss: @vardana_app.uid, sub: @vardana_app.uid, aud: VardanaAuthWorld::VARDANA_TOKEN_AUD,
             exp: 4.minutes.from_now.to_i, jti: SecureRandom.uuid }
  assertion = JWT.encode(claims, @vardana_key.public_key.to_pem, "HS384", { kid: @vardana_jwk.kid })
  vardana_post_token(assertion, scope: "system/Patient.read")
end

# --- Token response assertions ----------------------------------------------

Then("the token response should grant scope {string}") do |scopes|
  refute_nil @response_json, "Expected JSON token response"
  assert_equal scopes.split.sort, @response_json["scope"].to_s.split.sort
end

Then("the token response should expire in at most {int} seconds") do |max_seconds|
  refute_nil @response_json, "Expected JSON token response"
  expires_in = @response_json["expires_in"].to_i
  assert expires_in.positive? && expires_in <= max_seconds,
    "Expected expires_in <= #{max_seconds}, got #{expires_in}"
end

# --- Per-organization patient fixtures --------------------------------------

Given("patient {int} is managed by organization {string}") do |dfn, org_id|
  patient = vardana_synthetic_patient(
    dfn: dfn, name: "DEMO,PATIENT#{dfn}", site_ien: vardana_site_ien(org_id)
  )
  stub_gateway(Lakeraven::EHR::PatientRepository, :find, patient)
end

Given("patient {int} has no managing organization on record") do |dfn|
  patient = vardana_synthetic_patient(dfn: dfn, name: "DEMO,PATIENT#{dfn}", site_ien: nil)
  stub_gateway(Lakeraven::EHR::PatientRepository, :find, patient)
end

Given("a patient search for {string} would match patients in organizations {string} and {string}") do |_query, org_a, org_b|
  patient_a = vardana_synthetic_patient(dfn: 900_001, name: "DEMO,ALPHA", site_ien: vardana_site_ien(org_a))
  patient_b = vardana_synthetic_patient(dfn: 900_002, name: "DEMO,BRAVO", site_ien: vardana_site_ien(org_b))
  @vardana_org_patients = { org_a => [ "900001" ], org_b => [ "900002" ] }
  stub_gateway(Lakeraven::EHR::PatientRepository, :search, [ patient_a, patient_b ])
end

# --- FHIR response assertions -----------------------------------------------

Then("the response should be a FHIR Patient with id {string}") do |id|
  body = JSON.parse(last_response.body)
  assert_equal "Patient", body["resourceType"]
  assert_equal id, body["id"]
end

Then("the Bundle should contain only patients managed by organization {string}") do |org_id|
  bundle = JSON.parse(last_response.body)
  assert_equal "Bundle", bundle["resourceType"]
  ids = Array(bundle["entry"])
    .select { |e| e.dig("resource", "resourceType") == "Patient" }
    .map { |e| e.dig("resource", "id") }
  refute_empty ids, "Expected the Bundle to contain the organization's own patients"
  assert_equal @vardana_org_patients.fetch(org_id).sort, ids.sort,
    "Expected only #{org_id} patients, got ids #{ids}"
end

# --- SMART configuration discovery ------------------------------------------

Then("the SMART configuration should list grant type {string}") do |grant|
  config = JSON.parse(last_response.body)
  assert_includes Array(config["grant_types_supported"]), grant
end

Then("the SMART configuration should list token auth method {string}") do |method|
  config = JSON.parse(last_response.body)
  assert_includes Array(config["token_endpoint_auth_methods_supported"]), method
end

Then("the SMART configuration should list signing algorithm {string}") do |alg|
  config = JSON.parse(last_response.body)
  assert_includes Array(config["token_endpoint_auth_signing_alg_values_supported"]), alg
end

Then("the SMART configuration should list scope {string}") do |scope|
  config = JSON.parse(last_response.body)
  assert_includes Array(config["scopes_supported"]), scope
end

Then("the SMART configuration token endpoint should be {string}") do |url|
  config = JSON.parse(last_response.body)
  assert_equal url, config["token_endpoint"]
end

# --- Resolved-resource enforcement fixtures/requests -------------------------

Given("patient {int} cannot be resolved but clinical records exist for that DFN") do |_dfn|
  # The Patient lookup fails while the clinical gateway still holds records —
  # the fail-open case the review flagged: enforcement must bind to the
  # RESOLVED patient and deny when resolution fails.
  stub_gateway(Lakeraven::EHR::PatientRepository, :find, nil)
  stub_gateway(Lakeraven::EHR::Observation, :for_patient,
    [ { datetime: "2026-01-01T00:00", bp: "120/80", pulse: "72" } ])
end

When("I request POST {string} with patient_dfn {string} and the Bearer token") do |path, dfn|
  header "Authorization", @fhir_headers["Authorization"]
  post path, { patient_dfn: dfn }
end

When("I request POST {string} without a patient and with the Bearer token") do |path|
  header "Authorization", @fhir_headers["Authorization"]
  post path, {}
end

When("I request POST {string} with a FHIR Patient body and the Bearer token") do |path|
  header "Authorization", @fhir_headers["Authorization"]
  header "Content-Type", "application/fhir+json"
  post path, {
    resourceType: "Patient",
    name: [ { family: "DEMO", given: [ "PATIENT" ] } ],
    gender: "male", birthDate: "1970-01-01"
  }.to_json
end

Given("the client has requested an export for patient {int}") do |dfn|
  header "Authorization", @fhir_headers["Authorization"]
  post "/lakeraven-ehr/exports", { patient_dfn: dfn.to_s }
  body = JSON.parse(last_response.body) rescue {}
  @vardana_export_id = body["id"]
  assert @vardana_export_id.present?,
    "Expected an export id, got #{last_response.status}: #{last_response.body[0..200]}"
end

Given("a second backend client bound to organization {string} holds a token with scope {string}") do |org_id, scopes|
  app = Doorkeeper::Application.create!(
    name: "Example Second Connector #{org_id}",
    redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
    scopes: scopes, confidential: true, organization_id: org_id
  )
  token = Doorkeeper::AccessToken.create!(application: app, scopes: scopes, expires_in: 300)
  @vardana_second_headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
end

When("the second client requests the first client's export status") do
  header "Authorization", @vardana_second_headers["Authorization"]
  get "/lakeraven-ehr/exports/#{@vardana_export_id}"
end

When("the second client requests the first client's export file") do
  header "Authorization", @vardana_second_headers["Authorization"]
  get "/lakeraven-ehr/exports/#{@vardana_export_id}/files/Patient.ndjson"
end

# --- JWKS transport ----------------------------------------------------------

Then("registering a backend client with jwks_uri {string} is rejected") do |uri|
  app = Doorkeeper::Application.new(
    name: "Example Transport Client",
    redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
    scopes: "system/Patient.read", confidential: true,
    jwks_uri: uri, organization_id: "rpms-organization-101"
  )
  refute app.valid?, "Expected registration with #{uri} to be rejected"
  assert app.errors[:jwks_uri].present?,
    "Expected a jwks_uri validation error, got #{app.errors.full_messages}"
end

Given("a backend client whose registered JWKS host resolves to {string}") do |address|
  vardana_register_client(name: "Example Org A Connector",
    scopes: "system/Patient.read", stub_fetch: false)
  vardana_stub_resolver("client.example.test" => [ address ])
  # No HTTP stub on purpose: the fetch must refuse before any request leaves.
end

Given("a backend client whose published JWKS is served over HTTPS from a public address") do
  vardana_register_client(name: "Example Org A Connector",
    scopes: "system/Patient.read", stub_fetch: false)
  vardana_stub_resolver("client.example.test" => [ "203.0.113.10" ])
  stub_request(:get, "https://client.example.test/.well-known/jwks.json")
    .to_return(status: 200, body: { keys: [ @vardana_jwk.export ] }.to_json,
               headers: { "Content-Type" => "application/json" })
end

Given("a backend client whose published JWKS endpoint fails on the first fetch and succeeds afterwards") do
  vardana_register_client(name: "Example Org A Connector",
    scopes: "system/Patient.read", stub_fetch: false)
  vardana_stub_resolver("client.example.test" => [ "203.0.113.10" ])
  stub_request(:get, "https://client.example.test/.well-known/jwks.json")
    .to_return({ status: 503 },
               { status: 200, body: { keys: [ @vardana_jwk.export ] }.to_json,
                 headers: { "Content-Type" => "application/json" } })
end
