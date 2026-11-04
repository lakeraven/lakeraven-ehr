# frozen_string_literal: true

module Lakeraven
  module EHR
    # A client authenticating with a signed JWT (private_key_jwt, RFC 7523),
    # checked against the key set the client publishes at its registered
    # jwks_uri. Used by Backend Services (BackendServicesController) and by a
    # SMART launch's confidential asymmetric client (SmartTokensController).
    #
    # Verifies the signature (only the algorithms the caller names: never
    # HMAC or "none"), aud, exp, iss and sub both naming the client, and a jti
    # that has not been seen. Every claim the verifier relies on must be
    # present: JWT.decode otherwise treats a missing exp as "never expires".
    #
    # A refusal raises Refused with a short reason for the log. The reason is
    # never sent to the caller: every client-authentication refusal looks the
    # same from outside, or it becomes a registry oracle.
    class ClientAssertion
      TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
      # SMART: the assertion's exp is no more than five minutes in the future,
      # with no skew allowance on top.
      MAX_LIFETIME = 5.minutes
      REQUIRED_CLAIMS = %w[iss sub aud exp jti].freeze

      class Refused < StandardError; end

      # The registered client the assertion claims to be (its unverified
      # iss), or nil. The signature is then checked against that client's keys.
      def self.claimed_client(assertion)
        return nil unless assertion.is_a?(String)

        unverified, = JWT.decode(assertion, nil, false)
        Doorkeeper::Application.find_by(uid: unverified["iss"])
      rescue JWT::DecodeError
        nil
      end

      def initialize(assertion, app:, audience:, algorithms:)
        @assertion = assertion
        @app = app
        @audience = audience
        @algorithms = algorithms
      end

      # The verified claims, or Refused.
      def verify!
        raise Refused, "undecodable" unless @assertion.is_a?(String)

        jwks = ClientJwks.fetch(@app.jwks_uri)
        raise Refused, "no_retrievable_jwks" unless jwks

        claims, = JWT.decode(
          @assertion, nil, true,
          algorithms: @algorithms,
          jwks: JWT::JWK::Set.new(jwks),
          verify_aud: true,
          aud: @audience,
          required_claims: REQUIRED_CLAIMS
        )
        check_claims!(claims)
        claims
      rescue JWT::ExpiredSignature
        raise Refused, "expired"
      rescue JWT::InvalidAudError
        raise Refused, "bad_audience"
      rescue JWT::DecodeError
        raise Refused, "undecodable"
      end

      private

      def check_claims!(claims)
        raise Refused, "iss_sub_mismatch" unless claims["iss"] == @app.uid && claims["sub"] == @app.uid

        exp = claims["exp"].to_i
        raise Refused, "exp_too_far" if exp > MAX_LIFETIME.from_now.to_i
        if claims["iat"].present? && exp - claims["iat"].to_i > MAX_LIFETIME.to_i
          raise Refused, "lifetime_too_long"
        end

        jti = claims["jti"].to_s
        raise Refused, "missing_jti" if jti.blank?
        raise Refused, "replayed_jti" if AssertionReplayGuard.replayed?(@app.uid, jti, exp)
      end
    end
  end
end
