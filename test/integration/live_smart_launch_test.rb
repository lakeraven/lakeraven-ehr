# frozen_string_literal: true

require "test_helper"

# Live (#839, #844): a SMART app launches against a real broker. PROFILE,MD
# signs in with their own codes through the real sign-in, approves the app, and
# the app swaps the code (PKCE S256, client secret) for a token that reads a
# Patient through FHIR. The read runs on PROFILE,MD's own RPMS connection, as
# PROFILE,MD: the connection's signed-on user is asked of RPMS itself, and the
# audit row names the same DUZ. Signing out ends the token. Reads only.
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9153 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_smart_launch_test.rb
class LiveSmartLaunchTest < ActionDispatch::IntegrationTest
  BASE = "/lakeraven-ehr"
  REDIRECT = "https://app.example/redirect"
  # The demo build's MOUSE,MICKEY M (live_patient_bar_search_test).
  DFN = "3"

  setup do
    skip "live: set LIVE_RPMS=1 against a local container" unless defined?(LIVE_RPMS) && LIVE_RPMS
    @shared = RpmsRpc.configuration.client
    RpmsRpc.reset! # a pooled process holds no shared client
    settings = Lakeraven::EHR::Engine.rpms_settings
    Lakeraven::EHR::RpmsSessions.configure!(
      factory: -> { RpmsRpc.client_for(settings[:broker], host: settings[:host], port: settings[:port]) },
      max_sessions: 4, keeper: false
    )
    Lakeraven::EHR::LoginThrottle.reset!
    @client = Doorkeeper::Application.create!(
      name: "Live example app", uid: "live-example-symmetric", secret: "live-example-secret",
      redirect_uri: REDIRECT, scopes: "user/*.rs", confidential: true
    )
    @verifier = SecureRandom.urlsafe_base64(48)
  end

  teardown do
    next unless defined?(LIVE_RPMS) && LIVE_RPMS

    Lakeraven::EHR::RpmsSessions.reset!
    RpmsRpc.configure { |c| c.client = @shared }
  end

  # The DUZ RPMS runs this pool key's RPCs as: CIAVCXUS VIMINFO answers for
  # the connection's own signed-on user.
  def rpms_user_of(pool_key)
    Lakeraven::EHR::RpmsSessions.with_user(pool_key) do
      Array(RpmsRpc.client.call_rpc("CIAVCXUS VIMINFO")).first.to_s.split("^").first
    end
  end

  test "PROFILE,MD launches an app, and its token reads a Patient on PROFILE,MD's own connection" do
    browser = open_session
    browser.get "#{BASE}/oauth/authorize", params: {
      response_type: "code", client_id: @client.uid, redirect_uri: REDIRECT,
      scope: "user/Patient.rs", state: "live-state", aud: "http://www.example.com#{BASE}",
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false),
      code_challenge_method: "S256"
    }
    browser.assert_redirected_to "#{BASE}/login"
    browser.post "#{BASE}/login", params: { username: "PMD123", password: "PMD123!!" }
    browser.assert_redirected_to "#{BASE}/oauth/authorize/approval"
    duz = browser.session[:duz]
    browser.follow_redirect!
    browser.assert_select "#granted-scopes li[data-scope='user/Patient.rs']"
    browser.post "#{BASE}/oauth/authorize/approval", params: { decision: "approve" }
    code = Rack::Utils.parse_query(URI.parse(browser.response.location).query).fetch("code")

    api = open_session
    api.post "#{BASE}/oauth/token",
      params: { grant_type: "authorization_code", code: code, redirect_uri: REDIRECT, code_verifier: @verifier },
      headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(@client.uid, "live-example-secret") }
    api.assert_response :ok
    access_token = JSON.parse(api.response.body).fetch("access_token")

    api.get "#{BASE}/Patient/#{DFN}", headers: { "Authorization" => "Bearer #{access_token}" }
    api.assert_response :ok
    assert_equal "Patient", JSON.parse(api.response.body)["resourceType"]

    authorization = Lakeraven::EHR::SmartAuthorization.for_access_token(Doorkeeper::AccessToken.by_token(access_token))
    assert_equal browser.session[:rpms_pool_key], authorization.pool_key, "the token is bound to the browser session"
    assert_equal duz, rpms_user_of(authorization.pool_key), "RPMS runs the token's connection as PROFILE,MD"
    audit = Lakeraven::EHR::AuditEvent.where(entity_type: "Patient").order(:id).last
    assert_equal duz, audit.agent_who_identifier, "the read is recorded as PROFILE,MD"
    assert_equal browser.session[:rpms_session_id], audit.rpms_session_id, "and under PROFILE,MD's RPMS session"

    browser.delete "#{BASE}/logout"
    refute Lakeraven::EHR::RpmsSessions.held?(authorization.pool_key), "signing out ends the connection"
    api.get "#{BASE}/Patient/#{DFN}", headers: { "Authorization" => "Bearer #{access_token}" }
    api.assert_response :unauthorized
  end
  test "a standalone launch/patient: PROFILE,MD finds and chooses the patient, and the token reads only that patient" do
    @client.update!(scopes: "patient/*.rs launch/patient")
    browser = open_session
    browser.get "#{BASE}/oauth/authorize", params: {
      response_type: "code", client_id: @client.uid, redirect_uri: REDIRECT,
      scope: "launch/patient patient/Patient.rs", state: "live-state", aud: "http://www.example.com#{BASE}",
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false),
      code_challenge_method: "S256"
    }
    browser.post "#{BASE}/login", params: { username: "PMD123", password: "PMD123!!" }
    browser.follow_redirect!
    browser.assert_redirected_to "#{BASE}/oauth/authorize/patient"
    browser.post "#{BASE}/oauth/authorize/patient", params: { q: "MOUSE" }
    browser.assert_select "#matches tr[data-dfn='#{DFN}'] td", text: "MOUSE,MICKEY M"
    browser.post "#{BASE}/oauth/authorize/patient", params: { dfn: DFN }
    browser.follow_redirect!
    browser.assert_select "#launch-patient[data-dfn='#{DFN}']"
    browser.post "#{BASE}/oauth/authorize/approval", params: { decision: "approve" }
    code = Rack::Utils.parse_query(URI.parse(browser.response.location).query).fetch("code")

    api = open_session
    api.post "#{BASE}/oauth/token",
      params: { grant_type: "authorization_code", code: code, redirect_uri: REDIRECT, code_verifier: @verifier },
      headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(@client.uid, "live-example-secret") }
    api.assert_response :ok
    body = JSON.parse(api.response.body)
    assert_equal DFN, body["patient"]
    assert_equal "launch/patient patient/Patient.rs", body["scope"]

    api.get "#{BASE}/Patient/#{DFN}", headers: { "Authorization" => "Bearer #{body["access_token"]}" }
    api.assert_response :ok
    api.get "#{BASE}/Patient/1", headers: { "Authorization" => "Bearer #{body["access_token"]}" }
    api.assert_response :forbidden
  end
end
