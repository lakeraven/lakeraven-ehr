# frozen_string_literal: true

require "test_helper"

# SMART launch context (#839): a standalone launch that asks for
# launch/patient has the user choose the patient with the chart's own search;
# an EHR launch carries the patient from smart/launch. The token response names
# the patient (and encounter), says whether the app shows a patient banner, and
# where this EHR's style is; a patient/ token reads only that patient.
class SmartLaunchContextTest < ActionDispatch::IntegrationTest
  BASE = "/lakeraven-ehr"
  AUD = "http://www.example.com/lakeraven-ehr"
  REDIRECT = "https://app.example/redirect"
  LAUNCH_URI = "https://app.example/launch"
  MOUSE = { name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), sex: "M", mrn: "1001" }.freeze

  setup do
    Lakeraven::EHR::LoginThrottle.reset!
    @client = Doorkeeper::Application.create!(
      name: "Example chart app", uid: "example-context", redirect_uri: REDIRECT, launch_uri: LAUNCH_URI,
      scopes: "user/*.rs patient/*.rs launch launch/patient", confidential: false
    )
    @verifier = SecureRandom.urlsafe_base64(48)
  end

  # RPMS at the gem boundary: the patient search finds DFN 3, and the brief
  # header knows DFNs 1 to 3 (the shapes rpms-ydb 7c3119b answered).
  def with_rpms(&block)
    stubs = {
      RpmsRpc::PatientSelection.singleton_class => { find: ->(_text) { [ { dfn: 3, name: "MOUSE,MICKEY M" } ] } },
      RpmsRpc::Patient.singleton_class => { brief_header: ->(dfn) { MOUSE if (1..3).cover?(dfn.to_i) } }
    }
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(:"__#{m}", m) } }
    stubs.each { |klass, methods| methods.each { |m, body| klass.define_method(m, &body) } }
    block.call
  ensure
    stubs.each { |klass, methods| methods.each_key { |m| klass.alias_method(m, :"__#{m}"); klass.remove_method(:"__#{m}") } }
  end

  def authorize(scope:, **extra)
    get "#{BASE}/oauth/authorize", params: {
      response_type: "code", client_id: @client.uid, redirect_uri: REDIRECT, scope: scope, state: "s", aud: AUD,
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false),
      code_challenge_method: "S256"
    }.merge(extra)
  end

  def sign_in(username = "testprovider")
    post "#{BASE}/login", params: { username: username, password: "test123" }
  end

  def approve_and_swap
    post "#{BASE}/oauth/authorize/approval", params: { decision: "approve" }
    code = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("code")
    api = open_session
    api.post "#{BASE}/oauth/token", params: {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT,
      code_verifier: @verifier, client_id: @client.uid
    }
    assert_equal 200, api.response.status
    JSON.parse(api.response.body)
  end

  def read(token, path)
    api = open_session
    api.get "#{BASE}/#{path}", headers: { "Authorization" => "Bearer #{token}" }
    api.response.status
  end

  test "a standalone launch/patient has the user choose the patient, and the token reads only that patient" do
    with_rpms do
      authorize(scope: "launch/patient openid fhirUser patient/Patient.rs patient/Observation.read")
      sign_in
      assert_redirected_to "#{BASE}/oauth/authorize/approval"
      follow_redirect!
      assert_redirected_to "#{BASE}/oauth/authorize/patient"
      follow_redirect!
      assert_select "#launch-patient-search"

      post "#{BASE}/oauth/authorize/patient", params: { q: "MOUSE" }
      assert_select "#matches tr[data-dfn='3'] td", text: "MOUSE,MICKEY M"
      post "#{BASE}/oauth/authorize/patient", params: { dfn: "3" }
      follow_redirect!
      assert_select "#launch-patient[data-dfn='3']", /MOUSE,MICKEY M/
      assert_select "#granted-scopes li", text: "See this patient's names, birth dates and contact details"

      body = approve_and_swap
      assert_equal "3", body["patient"]
      assert_equal true, body["need_patient_banner"]
      assert_equal "#{AUD}/smart/style", body["smart_style_url"]
      assert_equal "launch/patient patient/Observation.rs patient/Patient.rs", body["scope"]
      assert_nil body["encounter"]

      assert_equal 200, read(body["access_token"], "Patient/3")
      assert_equal 403, read(body["access_token"], "Patient/1"), "a patient token reads only its patient"
    end
  end

  test "a chosen patient RPMS does not know is refused" do
    with_rpms do
      authorize(scope: "launch/patient patient/Patient.rs")
      sign_in
      post "#{BASE}/oauth/authorize/patient", params: { dfn: "999" }

      assert_response :bad_request
    end
  end

  test "an EHR launch carries the patient and encounter from smart/launch to the token" do
    with_rpms do
      sign_in
      get "#{BASE}/smart/launch", params: { patient: "3" }
      assert_select "#launch-apps li[data-client-id='#{@client.uid}']"

      post "#{BASE}/smart/launch", params: { client_id: @client.uid, patient: "3", encounter: "42" }
      launch_uri = URI.parse(response.location)
      assert_equal LAUNCH_URI, "#{launch_uri.scheme}://#{launch_uri.host}#{launch_uri.path}"
      query = Rack::Utils.parse_query(launch_uri.query)
      assert_equal AUD, query["iss"]

      authorize(scope: "launch user/Patient.rs patient/Patient.rs", launch: query["launch"])
      follow_redirect!
      assert_select "#launch-patient[data-dfn='3']"

      body = approve_and_swap
      assert_equal "3", body["patient"]
      assert_equal "42", body["encounter"]
      assert_equal "launch patient/Patient.rs user/Patient.rs", body["scope"]
    end
  end

  test "a launch works once, for the user who started it" do
    with_rpms do
      sign_in
      post "#{BASE}/smart/launch", params: { client_id: @client.uid, patient: "3" }
      launch = Rack::Utils.parse_query(URI.parse(response.location).query)["launch"]

      sign_in("testnurse")
      authorize(scope: "launch patient/Patient.rs", launch: launch)
      follow_redirect!
      assert_response :bad_request
      assert_select "#refusal-reason", /started by someone else/

      sign_in
      authorize(scope: "launch patient/Patient.rs", launch: launch)
      follow_redirect!
      approve_and_swap
      authorize(scope: "launch patient/Patient.rs", launch: launch)
      assert_equal "invalid_request", Rack::Utils.parse_query(URI.parse(response.location).query)["error"]
    end
  end

  test "an unknown launch goes back to the app as an error" do
    authorize(scope: "launch patient/Patient.rs", launch: "lc_nothing")

    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal "invalid_request", query["error"]
    assert_nil query["code"]
  end

  test "smart/launch goes only to an app's registered launch URI" do
    with_rpms do
      sign_in
      other = Doorkeeper::Application.create!(name: "No launch URI", uid: "no-launch", redirect_uri: REDIRECT, confidential: false)
      post "#{BASE}/smart/launch", params: { client_id: other.uid, patient: "3" }

      assert_response :not_found
    end
  end

  test "smart/launch takes the user's own Patient read" do
    with_rpms do
      sign_in("testclerk")
      get "#{BASE}/smart/launch", params: { patient: "3" }

      assert_response :forbidden
    end
  end

  test "the smart_style_url answers JSON" do
    get "#{BASE}/smart/style"

    assert_response :ok
    assert_equal "sss-0.1", JSON.parse(response.body)["sms_style_version"]
  end
end
