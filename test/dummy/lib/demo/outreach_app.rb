# frozen_string_literal: true

require "openssl"
require "securerandom"
require "json"
require "jwt"

module Demo
  # A stand-in for an outside outreach app (for example an AI voice app that
  # calls patients about open referrals), for the referral-loop demo (#993).
  #
  # PROTOTYPE, not for merge. It talks to the engine through the same HTTP
  # routes a real app would use, but in-process (ActionDispatch integration
  # session), so the demo needs no network, no third-party service and no
  # live RPMS. A real outside app can replace it: everything it does is
  # plain SMART Backend Services and FHIR over HTTP.
  #
  # Synthetic data only.
  class OutreachApp
    CLIENT_ID = "demo-outreach-app"
    NAME = "Demo Outreach App (synthetic)"
    JWKS_URI = "https://outreach-app.example.test/.well-known/jwks.json"
    ORGANIZATION_ID = "demo-organization-riverbend"
    SCOPES = "system/Patient.read system/ServiceRequest.read system/Communication.c"
    MOUNT = "/lakeraven-ehr"

    attr_reader :http, :token, :key

    def initialize(rails_app)
      @http = ActionDispatch::Integration::Session.new(rails_app)
      @http.host! "localhost"
      @key = OpenSSL::PKey::RSA.new(2048)
      @jwk = JWT::JWK.new(@key, kid: "demo-outreach-key-1", alg: "RS384")
    end

    # Registers the app the way a site admin would (a Doorkeeper application
    # bound to the site's organization, with the app's published JWKS).
    def register!
      Doorkeeper::Application.where(uid: CLIENT_ID).destroy_all
      Doorkeeper::Application.create!(
        name: NAME, uid: CLIENT_ID, redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
        scopes: SCOPES, confidential: true, jwks_uri: JWKS_URI,
        organization_id: ORGANIZATION_ID
      )
    end

    # The JWKS a real app would publish at JWKS_URI. The demo cannot host it
    # on the public internet, so the rake task answers that one URI with it.
    def published_jwks
      { keys: [ @jwk.export ] }
    end

    # SMART Backend Services: client_credentials with a signed JWT assertion.
    def request_token!(scope: SCOPES)
      now = Time.now.to_i
      assertion = JWT.encode(
        { iss: CLIENT_ID, sub: CLIENT_ID, aud: "http://localhost#{MOUNT}/oauth/token",
          jti: SecureRandom.uuid, iat: now, exp: now + 240 },
        @key, "RS384", { kid: @jwk.kid, typ: "JWT" }
      )
      http.post "#{MOUNT}/oauth/token", params: {
        grant_type: "client_credentials",
        client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        client_assertion: assertion,
        scope: scope
      }
      body = parse(http.response)
      @token = body["access_token"]
      [ http.response.status, body ]
    end

    def get(path, params = {})
      http.get "#{MOUNT}/#{path}", params: params, headers: auth_headers
      [ http.response.status, parse(http.response) ]
    end

    def post_fhir(path, resource)
      http.post "#{MOUNT}/#{path}", params: resource.to_json,
        headers: auth_headers.merge("CONTENT_TYPE" => "application/fhir+json")
      [ http.response.status, parse(http.response) ]
    end

    private

    def auth_headers
      { "Authorization" => "Bearer #{@token}", "Accept" => "application/fhir+json" }
    end

    def parse(response)
      JSON.parse(response.body)
    rescue JSON::ParserError
      { "raw" => response.body.to_s[0, 200] }
    end
  end
end
