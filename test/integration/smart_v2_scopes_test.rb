# frozen_string_literal: true

require "test_helper"

# SMART App Launch v2 scopes. The engine mints v2 (`system/Patient.rs`),
# checks v2, and accepts v1 (`system/Patient.read`) by translating it, so a
# v1 client and a v2 client holding the same grant reach the same data.
# scopes_supported lists only what the token endpoint grants and the API
# honours (#658).
class SmartV2ScopesTest < ActionDispatch::IntegrationTest
  ENGINE = "/lakeraven-ehr"
  TOKEN_URL = "#{ENGINE}/oauth/token".freeze
  TOKEN_AUD = "http://www.example.com/lakeraven-ehr/oauth/token"
  JWKS_URI = "https://v2-client.example.test/.well-known/jwks.json"
  V2_SCOPE = %r{\A(patient|user|system)/([A-Z][A-Za-z]*|\*)\.c?r?u?d?s?\z}

  # The test's own reading of a scope, independent of the engine's, so the
  # oracle is not the code under test: v1 suffixes spelled out as the SMART
  # v2 permissions they stand for.
  V1_AS_V2 = { "read" => "rs", "write" => "cud", "*" => "cruds" }.freeze
  INTERACTION = { "c" => "create", "r" => "read", "s" => "search-type" }.freeze

  setup do
    @client_key = OpenSSL::PKey::RSA.new(2048)
    @client_jwk = JWT::JWK.new(@client_key)
    known = { JWKS_URI => { keys: [ @client_jwk.export ] } }
    Lakeraven::EHR::ClientJwks.singleton_class.send(:alias_method, :fetch_without_stub, :fetch)
    Lakeraven::EHR::ClientJwks.define_singleton_method(:fetch) { |uri| known[uri] }
    Lakeraven::EHR::LoginThrottle.reset!
  end

  teardown do
    jwks = Lakeraven::EHR::ClientJwks.singleton_class
    if jwks.method_defined?(:fetch_without_stub)
      jwks.send(:remove_method, :fetch)
      jwks.send(:alias_method, :fetch, :fetch_without_stub)
      jwks.send(:remove_method, :fetch_without_stub)
    end
    Lakeraven::EHR::LoginThrottle.reset!
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
    Lakeraven::EHR::BackendAssertionJti.delete_all
  end

  # -- scopes_supported (#658) ---------------------------------------------

  # Each advertised scope is granted by the token endpoint as advertised, and
  # every permission it names is honoured by a declared interaction on a type
  # it covers: a token holding it passes the scope check where a token
  # without it is refused. A wildcard write fails this: nothing serves an
  # update.
  test "every scope in scopes_supported is grantable by the token endpoint and honoured by the API" do
    declared = declared_interactions

    scopes_supported.each do |scope|
      type, permissions = split_scope(scope)
      assert_match %r{\Asystem/}, scope, "a client can obtain only system/ scopes from this server"
      types = type == "*" ? declared.keys : [ type ]

      permissions.each_char do |permission|
        interaction = INTERACTION[permission]
        target = types.find { |t| declared.fetch(t, []).include?(interaction) }
        assert target, "#{scope}: no declared interaction honours `#{permission}`"

        # A create can also need read scope for what it hands back
        # (discloses_clinical_data); the companion supplies that, and the
        # refusal without the scope under test shows the scope is what
        # passes the check.
        companion = permission == "c" ? [ "system/*.rs" ] : []
        token = grant(([ scope ] + companion).uniq)
        perform(token, interaction, target)
        refute_includes [ 401, 403 ], response.status, "#{scope} on #{interaction} #{target}: #{response.body}"

        perform(bare_token(companion), interaction, target)
        assert_includes [ 401, 403 ], response.status,
          "#{interaction} #{target} answered without #{scope}, so the check proves nothing"
      end
    end
  end

  # -- v1 and v2 grant the same access -------------------------------------

  V1_V2_PAIRS = [
    %w[system/Patient.read system/Patient.rs],
    %w[system/*.read system/*.rs],
    %w[system/Patient.write system/Patient.cud],
    %w[system/Patient.* system/Patient.cruds],
    %w[system/*.* system/*.cruds],
    %w[user/Practitioner.read user/Practitioner.rs],
    %w[system/Condition.read system/Condition.rs]
  ].freeze

  REQUESTS = [
    [ :get, "Patient", { _id: "1" } ],
    [ :get, "Patient/1", {} ],
    [ :post, "Patient", "{}" ],
    [ :get, "Practitioner/101", {} ],
    [ :get, "Practitioner", { name: "CHEN" } ],
    [ :get, "Condition", { patient: "1" } ],
    [ :get, "Measure", {} ]
  ].freeze

  test "a v1 scope and its v2 spelling answer every request identically" do
    V1_V2_PAIRS.each do |v1, v2|
      v1_token = bare_token([ v1 ])
      v2_token = bare_token([ v2 ])

      REQUESTS.each do |verb, path, params|
        v1_status = request_status(v1_token, verb, path, params)
        v2_status = request_status(v2_token, verb, path, params)

        assert_equal v1_status, v2_status, "#{verb.upcase} #{path}: #{v1} gave #{v1_status}, #{v2} gave #{v2_status}"
      end
    end
  end

  # The split v2 makes: search without read by id, and the reverse.
  test "a v2 search permission searches and does not read by id" do
    token = bare_token(%w[system/Patient.s])

    assert_equal 200, request_status(token, :get, "Patient", { _id: "1" })
    assert_equal 403, request_status(token, :get, "Patient/1", {})
  end

  test "a v2 read permission reads by id and does not search" do
    token = bare_token(%w[system/Patient.r])

    assert_equal 200, request_status(token, :get, "Patient/1", {})
    assert_equal 403, request_status(token, :get, "Patient", { _id: "1" })
  end

  # -- registrations and minting ---------------------------------------------

  test "a v1 client registration is granted the v2 scope a client requests, and the reverse" do
    register_client("system/Patient.read")
    assert_equal "system/Patient.rs", token_response("system/Patient.rs")["scope"]

    remove_client
    register_client("system/*.rs")
    assert_equal "system/Patient.rs", token_response("system/Patient.read")["scope"]
  end

  test "a request for more permissions than registered is granted the registered ones" do
    register_client("system/Patient.read")

    assert_equal "system/Patient.rs", token_response("system/Patient.cruds")["scope"]
  end

  test "the backend token endpoint mints v2 scopes" do
    register_client("system/*.read system/Patient.write")
    granted = token_response("system/*.read system/Patient.write")["scope"].split

    assert_equal %w[system/*.rs system/Patient.cud], granted
  end

  test "a browser session is minted v2 scopes" do
    post "#{ENGINE}/login", params: { username: "lindarodriguez", password: "test123" }
    scopes = Doorkeeper::AccessToken.order(:id).last.scopes.to_a

    assert_not_empty scopes
    scopes.each { |scope| assert_match V2_SCOPE, scope }
  end

  test "every scope a browser session can be minted is v2" do
    scopes = Lakeraven::EHR::SessionScopePolicy.all_scopes

    assert_not_empty scopes
    scopes.each { |scope| assert_match V2_SCOPE, scope }
  end

  private

  def scopes_supported
    get "#{ENGINE}/.well-known/smart-configuration"
    JSON.parse(response.body).fetch("scopes_supported")
  end

  def declared_interactions
    get "#{ENGINE}/metadata"
    JSON.parse(response.body).dig("rest", 0, "resource").to_h do |resource|
      [ resource["type"], resource["interaction"].map { |i| i["code"] } ]
    end
  end

  # [type, v2 permissions] for a clinical scope. Anything else (openid,
  # launch) gets a permission no interaction honours, so it fails.
  def split_scope(scope)
    match = %r{\A(?:patient|user|system)/([A-Za-z]+|\*)\.([a-z*]+)\z}.match(scope)
    return [ nil, "?" ] unless match

    [ match[1], V1_AS_V2.fetch(match[2], match[2]) ]
  end

  def perform(token, interaction, type)
    headers = { "Authorization" => "Bearer #{token}" }
    case interaction
    when "read" then get "#{ENGINE}/#{type}/1", headers: headers
    when "search-type" then get "#{ENGINE}/#{type}", headers: headers
    when "create"
      post "#{ENGINE}/#{type}", params: "{}", headers: headers.merge("Content-Type" => "application/fhir+json")
    end
  end

  def request_status(token, verb, path, params)
    headers = { "Authorization" => "Bearer #{token}" }
    if verb == :post
      post "#{ENGINE}/#{path}", params: params, headers: headers.merge("Content-Type" => "application/fhir+json")
    else
      get "#{ENGINE}/#{path}", params: params, headers: headers
    end
    response.status
  end

  # A token straight from Doorkeeper, as a client registration from before
  # this change would hold.
  def bare_token(scopes)
    app = Doorkeeper::Application.create!(name: "bare #{SecureRandom.hex(4)}",
                                          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
                                          scopes: scopes.join(" "), confidential: true)
    token = Doorkeeper::AccessToken.create!(application: app, scopes: scopes.join(" "), expires_in: 3600)
    token.plaintext_token || token.token
  end

  # A token from the token endpoint, for a client registered with exactly
  # these scopes and asking for all of them.
  def grant(scopes)
    remove_client
    register_client(scopes.join(" "))
    body = token_response(scopes.join(" "))

    assert_equal 200, response.status, "token endpoint refused #{scopes.join(' ')}: #{body}"
    assert_equal scopes.sort, body["scope"].split.sort, "the token endpoint must grant what it advertises"
    body["access_token"]
  end

  def register_client(scopes)
    Doorkeeper::Application.create!(name: "v2 client", uid: "v2-client",
                                    redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
                                    scopes: scopes, confidential: true,
                                    jwks_uri: JWKS_URI, organization_id: "example-organization-1")
  end

  def remove_client
    Doorkeeper::Application.where(uid: "v2-client").find_each do |app|
      Doorkeeper::AccessToken.where(application_id: app.id).delete_all
      app.delete
    end
  end

  def token_response(scope)
    claims = { iss: "v2-client", sub: "v2-client", aud: TOKEN_AUD, exp: 5.minutes.from_now.to_i, jti: SecureRandom.uuid }
    post TOKEN_URL, params: {
      grant_type: "client_credentials",
      client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      client_assertion: JWT.encode(claims, @client_key, "RS384", kid: @client_jwk[:kid]),
      scope: scope
    }
    JSON.parse(response.body)
  end
end
