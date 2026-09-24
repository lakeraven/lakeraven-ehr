# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class BackendServicesControllerTest < ActionDispatch::IntegrationTest
      TOKEN_URL = "/lakeraven-ehr/oauth/token"
      TOKEN_AUD = "http://www.example.com/lakeraven-ehr/oauth/token"

      setup do
        # A real keypair: the assertion is genuinely signed, so each negative
        # case below fails for the reason it names rather than falling out at
        # the signature check.
        # Ported from a static public_key column to the JWKS mechanism that
        # superseded it: the client publishes a key set and the endpoint
        # fetches it. The key that signs below is the one the JWKS serves.
        @client_key = OpenSSL::PKey::RSA.new(2048)
        @client_jwk = JWT::JWK.new(@client_key)
        @backend_app = Doorkeeper::Application.create!(
          name: "Example Backend",
          uid: "example-backend-client",
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "system/*.read",
          confidential: true,
          jwks_uri: "https://example-backend.example.test/.well-known/jwks.json",
          organization_id: "example-organization-1"
        )
        # Stubbed here rather than through a seam in ClientJwks: the fetch is
        # network I/O, and production code should not carry a test hook.
        @jwks_payload = { keys: [ @client_jwk.export ] }
        payload = @jwks_payload
        ClientJwks.singleton_class.send(:alias_method, :fetch_without_stub, :fetch)
        ClientJwks.define_singleton_method(:fetch) { |_uri| payload }
        ExportsController.reset_store!
      end

      teardown do
        if ClientJwks.singleton_class.method_defined?(:fetch_without_stub)
          ClientJwks.define_singleton_method(:fetch) { |uri| fetch_without_stub(uri) }
          ClientJwks.singleton_class.send(:remove_method, :fetch_without_stub)
        end
        ExportsController.reset_store!
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
        # Without this the fixed jti below survives between runs, so the second
        # post is refused by a LEFTOVER row and the replay test passes even
        # when the guard is removed.
        BackendAssertionJti.delete_all
      end

      test "forged signature is rejected" do
        post_token(assertion(signature: "not-a-signature"))

        assert_response :unauthorized
        assert_equal "invalid_client", JSON.parse(response.body)["error"]
      end

      test "an alg none assertion is rejected" do
        # `header.payload.` is NOT the test: String#split drops the trailing
        # empty segment, so it is refused on segment count and proves nothing
        # about algorithm handling. Three segments with alg "none" is the case
        # that must be refused on its own merits.
        header_b64 = Base64.urlsafe_encode64({ alg: "none", typ: "JWT" }.to_json, padding: false)
        payload_b64 = Base64.urlsafe_encode64(claims.to_json, padding: false)
        post_token("#{header_b64}.#{payload_b64}.#{Base64.urlsafe_encode64('ignored', padding: false)}")

        assert_response :unauthorized
        assert_equal "invalid_client", JSON.parse(response.body)["error"]
      end

      test "a signature from the wrong key is rejected" do
        other_key = OpenSSL::PKey::RSA.new(2048)
        post_token(assertion(claims, key: other_key))

        assert_response :unauthorized
        assert_equal "invalid_client", JSON.parse(response.body)["error"]
      end

      test "a correctly signed assertion is accepted and granted its registered scope" do
        post_token(assertion(claims))

        assert_response :success
        assert_equal "system/*.read", JSON.parse(response.body)["scope"]
      end

      test "expired exp is rejected" do
        post_token(assertion(claims(exp: 1.hour.ago.to_i)))

        assert_response :unauthorized
        assert_equal "invalid_client", JSON.parse(response.body)["error"]
      end

      test "wrong aud is rejected" do
        post_token(assertion(claims(aud: "https://not-the-token-endpoint.example/oauth/token")))

        assert_response :unauthorized
        assert_equal "invalid_client", JSON.parse(response.body)["error"]
      end

      test "replayed jti is rejected" do
        jwt = assertion(claims(jti: "replayed-jti-example"))
        post_token(jwt)
        assert_response :success, "the first presentation must be accepted, or this is not a replay test"

        post_token(jwt)

        assert_response :unauthorized
        assert_equal "invalid_client", JSON.parse(response.body)["error"]
      end

      test "iss different from sub is rejected" do
        post_token(assertion(claims(sub: "other-backend-client")))

        assert_response :unauthorized
        assert_equal "invalid_client", JSON.parse(response.body)["error"]
      end

      test "requested scope beyond registered scopes is not on the issued token" do
        post_token(assertion(claims), scope: "system/*.write")

        # A refusal is the correct outcome here: nothing in the request is
        # registered to this client. Asserted explicitly, because a test that
        # accepts either a 200 or a 400 passes whatever the endpoint does.
        assert_response :bad_request
        assert_equal "invalid_scope", JSON.parse(response.body)["error"]
        assert_nil Doorkeeper::AccessToken.order(:created_at).last,
          "no token may be issued when no requested scope is registered"
      end

      test "a request mixing registered and unregistered scopes is granted only the registered ones" do
        post_token(assertion(claims), scope: "system/*.read system/*.write")

        assert_response :success
        assert_equal "system/*.read", JSON.parse(response.body)["scope"]
      end

      test "refusals do not reveal whether a client exists or has a key" do
        # A per-reason description let an unauthenticated caller walk the client
        # registry: "Unknown client" vs "Client has no registered public key"
        # vs "Assertion signature does not verify", all before any signature was
        # checked. Every refusal must look identical from outside.
        keyless = Doorkeeper::Application.create!(
          name: "Keyless Backend",
          uid: "keyless-backend-client",
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          scopes: "system/*.read",
          confidential: true,
          organization_id: "example-organization-2"
        )

        post_token(assertion(claims(iss: "no-such-client", sub: "no-such-client")))
        unknown = JSON.parse(response.body)

        post_token(assertion(claims(iss: keyless.uid, sub: keyless.uid)))
        no_key = JSON.parse(response.body)

        post_token(assertion(claims, signature: "not-a-signature"))
        bad_sig = JSON.parse(response.body)

        assert_equal unknown, no_key,
          "an unknown client and a key-less client must be indistinguishable"
        assert_equal unknown, bad_sig,
          "a registry miss and a signature failure must be indistinguishable"
      end

      test "escalated scope does not authorize a downstream export" do
        post_token(assertion(claims), scope: "system/*.read system/*.write")
        token = JSON.parse(response.body)["access_token"]

        post "/lakeraven-ehr/exports",
          headers: { "Authorization" => "Bearer #{token}" }

        assert_response :forbidden
      end

      private

      def claims(overrides = {})
        {
          iss: @backend_app.uid,
          sub: @backend_app.uid,
          aud: TOKEN_AUD,
          exp: 5.minutes.from_now.to_i,
          jti: SecureRandom.uuid
        }.merge(overrides)
      end

      # signature: replaces the real signature with the given string, for the
      # forged case. key: signs with a different key than the JWKS publishes.
      def assertion(payload = claims, signature: nil, key: nil)
        jwt = JWT.encode(payload, key || @client_key, "RS256", kid: @client_jwk[:kid])
        return jwt unless signature

        head, body, = jwt.split(".")
        "#{head}.#{body}.#{signature}"
      end

      def post_token(jwt, scope: "system/*.read")
        post TOKEN_URL, params: {
          grant_type: "client_credentials",
          client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
          client_assertion: jwt,
          scope: scope
        }
      end
    end
  end
end
