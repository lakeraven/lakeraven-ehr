# frozen_string_literal: true

require "test_helper"

# SMART App Launch client types (#839): a public client proves itself with
# PKCE alone, and a confidential asymmetric client with a JWT signed by a key
# from the key set it publishes (RS384 or ES384). Each authenticates the way
# its registration says, and no other way.
class SmartLaunchClientTypesTest < ActionDispatch::IntegrationTest
  BASE = "/lakeraven-ehr"
  AUD = "http://www.example.com/lakeraven-ehr"
  TOKEN_URL = "http://www.example.com/lakeraven-ehr/oauth/token"
  REDIRECT = "https://app.example/redirect"
  JWKS_URI = "https://app.example/.well-known/jwks.json"

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
    @public_client = Doorkeeper::Application.create!(
      name: "Example public app", uid: "example-public", redirect_uri: REDIRECT,
      scopes: "user/*.rs", confidential: false
    )
    @asymmetric_client = Doorkeeper::Application.create!(
      name: "Example asymmetric app", uid: "example-asymmetric", redirect_uri: REDIRECT,
      scopes: "user/*.rs", confidential: true, jwks_uri: JWKS_URI
    )
    @rsa = OpenSSL::PKey::RSA.new(2048)
    @ec = OpenSSL::PKey::EC.generate("secp384r1")
    keys = { JWKS_URI => { keys: [ JWT::JWK.new(@rsa).export, JWT::JWK.new(@ec).export ] } }
    jwks = Lakeraven::EHR::ClientJwks.singleton_class
    jwks.send(:alias_method, :fetch_without_stub, :fetch)
    Lakeraven::EHR::ClientJwks.define_singleton_method(:fetch) { |uri| keys[uri] }
    @verifier = SecureRandom.urlsafe_base64(48)
  end

  teardown do
    jwks = Lakeraven::EHR::ClientJwks.singleton_class
    if jwks.method_defined?(:fetch_without_stub)
      jwks.send(:remove_method, :fetch)
      jwks.send(:alias_method, :fetch, :fetch_without_stub)
      jwks.send(:remove_method, :fetch_without_stub)
    end
  end

  def approved_code(client)
    get "#{BASE}/oauth/authorize", params: {
      response_type: "code", client_id: client.uid, redirect_uri: REDIRECT,
      scope: "user/Patient.rs", state: "s", aud: AUD,
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false),
      code_challenge_method: "S256"
    }
    post "#{BASE}/login", params: { username: "testprovider", password: "test123" }
    post "#{BASE}/oauth/authorize/approval", params: { decision: "approve" }
    Rack::Utils.parse_query(URI.parse(response.location).query).fetch("code")
  end

  def swap(code, headers: {}, **client_auth)
    api = open_session
    api.post "#{BASE}/oauth/token",
      params: { grant_type: "authorization_code", code: code, redirect_uri: REDIRECT, code_verifier: @verifier }.merge(client_auth),
      headers: headers
    api.response
  end

  def assertion(key: @rsa, alg: "RS384", **claims)
    payload = { iss: @asymmetric_client.uid, sub: @asymmetric_client.uid, aud: TOKEN_URL,
                exp: 4.minutes.from_now.to_i, jti: SecureRandom.uuid }.merge(claims)
    JWT.encode(payload, key, alg, kid: JWT::JWK.new(key)[:kid])
  end

  def asserted(jwt)
    { client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer", client_assertion: jwt }
  end

  test "a public client swaps its code with its client_id and PKCE alone" do
    response = swap(approved_code(@public_client), client_id: @public_client.uid)

    assert_equal 200, response.status
    assert_equal "user/Patient.rs", JSON.parse(response.body)["scope"]
  end

  test "a public client still needs the right code_verifier" do
    code = approved_code(@public_client)
    @verifier = SecureRandom.urlsafe_base64(48)

    assert_equal 400, swap(code, client_id: @public_client.uid).status
  end

  test "a confidential asymmetric client authenticates with an RS384 or ES384 assertion" do
    [ [ @rsa, "RS384" ], [ @ec, "ES384" ] ].each do |key, alg|
      response = swap(approved_code(@asymmetric_client), **asserted(assertion(key: key, alg: alg)))

      assert_equal 200, response.status, alg
    end
  end

  test "an asymmetric client's assertion is refused when forged, replayed, for another audience or the wrong algorithm" do
    other = OpenSSL::PKey::RSA.new(2048)
    replayed = assertion
    assert_equal 200, swap(approved_code(@asymmetric_client), **asserted(replayed)).status

    [
      assertion(key: other),
      replayed,
      assertion(aud: "https://other.example/token"),
      assertion(alg: "RS256"),
      assertion(exp: 10.minutes.from_now.to_i)
    ].each do |jwt|
      assert_equal 401, swap(approved_code(@asymmetric_client), **asserted(jwt)).status
    end
  end

  test "a client cannot authenticate in a weaker way than its registration says" do
    code = approved_code(@asymmetric_client)
    assert_equal 401, swap(code, client_id: @asymmetric_client.uid).status, "asymmetric without an assertion"

    symmetric = Doorkeeper::Application.create!(
      name: "Example symmetric app", uid: "example-symmetric", secret: "example-secret",
      redirect_uri: REDIRECT, scopes: "user/*.rs", confidential: true
    )
    code = approved_code(symmetric)
    assert_equal 401, swap(code, client_id: symmetric.uid).status, "symmetric without its secret"
  end

  test "one client's code is no use to another" do
    code = approved_code(@public_client)

    assert_equal 400, swap(code, **asserted(assertion)).status
  end

  test "a Backend Services client cannot launch" do
    backend = Doorkeeper::Application.create!(
      name: "Example backend", uid: "example-backend", redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "system/*.rs", confidential: true, jwks_uri: JWKS_URI, organization_id: "example-org"
    )
    get "#{BASE}/oauth/authorize", params: {
      response_type: "code", client_id: backend.uid, redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scope: "user/Patient.rs", aud: AUD, code_challenge: "x", code_challenge_method: "S256"
    }

    assert_response :bad_request
  end
end
