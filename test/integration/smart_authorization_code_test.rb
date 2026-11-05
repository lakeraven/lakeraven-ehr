# frozen_string_literal: true

require "test_helper"

# SMART App Launch, authorization code with PKCE (#839), for a confidential
# client that authenticates with a client secret. The user signs in with their
# own RPMS codes, approves, and the app's token reads as that user, for as long
# as that user's session stands (#844).
class SmartAuthorizationCodeTest < ActionDispatch::IntegrationTest
  BASE = "/lakeraven-ehr"
  AUD = "http://www.example.com/lakeraven-ehr"
  REDIRECT = "https://app.example/redirect"

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
    @client = Doorkeeper::Application.create!(
      name: "Example chart app", uid: "example-symmetric", secret: "example-secret",
      redirect_uri: REDIRECT, scopes: "user/*.rs", confidential: true
    )
    @verifier = SecureRandom.urlsafe_base64(48)
  end

  def challenge(verifier = @verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end

  def authorize_params(**overrides)
    {
      response_type: "code", client_id: @client.uid, redirect_uri: REDIRECT,
      scope: "user/Patient.rs user/Observation.read", state: "state-123", aud: AUD,
      code_challenge: challenge, code_challenge_method: "S256"
    }.merge(overrides)
  end

  def sign_in(username = "testprovider", password = "test123")
    post "#{BASE}/login", params: { username: username, password: password }
  end

  # Authorize, sign in, approve: the code the app is handed.
  def approved_code(username: "testprovider", **overrides)
    get "#{BASE}/oauth/authorize", params: authorize_params(**overrides)
    assert_redirected_to "#{BASE}/login"
    sign_in(username)
    assert_redirected_to "#{BASE}/oauth/authorize/approval"
    post "#{BASE}/oauth/authorize/approval", params: { decision: "approve" }
    assert_response :redirect
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal "state-123", query["state"]
    query.fetch("code")
  end

  def basic(id = @client.uid, secret = "example-secret")
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(id, secret) }
  end

  def swap(code, verifier: @verifier, headers: basic, **extra)
    api = open_session
    api.post "#{BASE}/oauth/token",
      params: { grant_type: "authorization_code", code: code, redirect_uri: REDIRECT, code_verifier: verifier }.merge(extra).compact,
      headers: headers
    api
  end

  def read_patient(access_token, dfn = "1")
    api = open_session
    api.get "#{BASE}/Patient/#{dfn}", headers: { "Authorization" => "Bearer #{access_token}" }
    api
  end

  test "a signed-in user approves, the app swaps the code, and reads a Patient as that user" do
    code = approved_code
    exchange = swap(code)

    assert_equal 200, exchange.response.status
    body = JSON.parse(exchange.response.body)
    assert_equal "Bearer", body["token_type"]
    assert_equal "user/Observation.rs user/Patient.rs", body["scope"], "v1 .read granted as v2 .rs"
    assert_operator body["expires_in"], :<=, Lakeraven::EHR::SmartAuthorization::TOKEN_LIFETIME.to_i
    assert_equal "no-store", exchange.response.headers["Cache-Control"]
    assert_equal "no-cache", exchange.response.headers["Pragma"]

    read = read_patient(body["access_token"])
    assert_equal 200, read.response.status
    audit = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient").order(:id).last
    assert_equal "Practitioner", audit.agent_who_type
    assert_equal "301", audit.agent_who_identifier, "the read is recorded as the user who approved it"
  end

  test "the approval screen names what the app may do, in plain words" do
    get "#{BASE}/oauth/authorize", params: authorize_params
    sign_in
    follow_redirect!

    assert_response :ok
    assert_select "#granted-scopes li", text: "See patients' names, birth dates and contact details"
    assert_select "#granted-scopes li", text: "See patients' vital signs and other results"
    assert_select "button[value=approve]", text: "Allow"
    assert_select "button[value=deny]", text: "Don't allow"
  end

  test "denying sends the app access_denied with its state, and no code" do
    get "#{BASE}/oauth/authorize", params: authorize_params
    sign_in
    post "#{BASE}/oauth/authorize/approval", params: { decision: "deny" }

    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal "access_denied", query["error"]
    assert_equal "state-123", query["state"]
    assert_nil query["code"]
  end

  test "authorize accepts POST, as the same request" do
    post "#{BASE}/oauth/authorize", params: authorize_params

    assert_response :see_other
    follow_redirect!
    assert_redirected_to "#{BASE}/login"
  end

  test "a user already signed in goes straight to the approval" do
    sign_in
    get "#{BASE}/oauth/authorize", params: authorize_params

    assert_redirected_to "#{BASE}/oauth/authorize/approval"
  end

  test "an app gets only what the user's own RPMS access allows" do
    get "#{BASE}/oauth/authorize", params: authorize_params
    sign_in("testclerk") # holds neither CIAV VUECENTRIC nor a key that reads Patient
    follow_redirect!

    assert_select "#nothing-to-grant"
    assert_select "button[value=approve]", count: 0
  end

  test "an aud that is not this server gets no code and no redirect" do
    get "#{BASE}/oauth/authorize", params: authorize_params(aud: "https://other.example/fhir")

    assert_response :bad_request
    assert_select "#refusal-reason", /different server/
  end

  test "an unknown client or an unregistered redirect URI is refused here, not sent back" do
    get "#{BASE}/oauth/authorize", params: authorize_params(client_id: "nobody")
    assert_response :bad_request

    get "#{BASE}/oauth/authorize", params: authorize_params(redirect_uri: "https://evil.example/cb")
    assert_response :bad_request
  end

  test "PKCE is required: no challenge, or the plain method, gets an error and no code" do
    [ { code_challenge: nil }, { code_challenge_method: "plain", code_challenge: @verifier } ].each do |bad|
      get "#{BASE}/oauth/authorize", params: authorize_params(**bad).compact

      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      assert_equal "invalid_request", query["error"]
      assert_nil query["code"]
    end
  end

  test "the token endpoint refuses a missing, blank or wrong code_verifier" do
    code = approved_code
    [ nil, "", SecureRandom.urlsafe_base64(48), @verifier.first(20) ].each do |verifier|
      exchange = swap(code, verifier: verifier)

      assert_equal 400, exchange.response.status, "verifier #{verifier.inspect}"
      assert_equal "invalid_grant", JSON.parse(exchange.response.body)["error"]
    end
  end

  test "the token endpoint refuses a bad code, a bad client, and a wrong secret" do
    code = approved_code

    assert_equal 400, swap("not-a-code").response.status
    assert_equal 401, swap(code, headers: basic("nobody")).response.status
    assert_equal 401, swap(code, headers: basic(@client.uid, "wrong")).response.status
    assert_equal 401, swap(code, headers: {}).response.status, "a confidential client must authenticate"
  end

  test "the client secret may come in the body instead of Basic" do
    code = approved_code
    exchange = swap(code, headers: {}, client_id: @client.uid, client_secret: "example-secret")

    assert_equal 200, exchange.response.status
  end

  test "a code works once; presenting it again also revokes the token it bought" do
    code = approved_code
    token = JSON.parse(swap(code).response.body)["access_token"]

    assert_equal 400, swap(code).response.status
    assert_equal 401, read_patient(token).response.status
  end

  test "a code expires" do
    code = approved_code

    travel(Lakeraven::EHR::SmartAuthorization::CODE_LIFETIME + 1.second) do
      assert_equal 400, swap(code).response.status
    end
  end

  test "signing out ends the launched token too" do
    code = approved_code
    token = JSON.parse(swap(code).response.body)["access_token"]
    assert_equal 200, read_patient(token).response.status

    delete "#{BASE}/logout"

    assert_equal 401, read_patient(token).response.status
    assert Doorkeeper::AccessToken.by_token(token).revoked?
  end

  test "signing in again elsewhere ends the launched token from the earlier session" do
    code = approved_code
    token = JSON.parse(swap(code).response.body)["access_token"]

    open_session { |other| other.post "#{BASE}/login", params: { username: "testprovider", password: "test123" } }

    assert_equal 401, read_patient(token).response.status
  end

  test "a code from a session that has since ended buys nothing" do
    code = approved_code
    delete "#{BASE}/logout"

    assert_equal 400, swap(code).response.status
  end

  test "the token never outlives the session" do
    Lakeraven::EHR.configuration.session_lifetime = 20.minutes
    code = approved_code
    body = JSON.parse(swap(code).response.body)

    assert_operator body["expires_in"], :<=, 20.minutes.to_i
  ensure
    Lakeraven::EHR.reset_configuration!
  end
end
