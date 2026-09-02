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

  def vardana_register_client(name:, scopes:, organization_id: nil, with_jwks: true)
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
    return unless with_jwks

    stub_gateway(Lakeraven::EHR::ClientJwks, :fetch, { keys: [ @vardana_jwk.export ] })
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
