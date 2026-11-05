# frozen_string_literal: true

module Lakeraven
  module EHR
    # One SMART App Launch authorization (#839): a signed-in RPMS user approved
    # a client's request, and the client swaps the one-time code for a token.
    #
    # The token is bound to the browser session the user approved it in (#844):
    # it reads RPMS on that session's own connection (ADR 0011), as that user and
    # nobody else, and it dies when that session does. Sign-out, the idle limit,
    # a new sign-in by the same user, and the session token's revocation or
    # expiry all end the session's token, and with it every token launched from
    # it. Its lifetime never runs past the session's.
    #
    # Only the code's SHA-256 digest is kept. A code is good once, for
    # CODE_LIFETIME, for the client and redirect URI it was issued to, and only
    # with the PKCE verifier whose S256 challenge the client sent at authorize.
    class SmartAuthorization < ApplicationRecord
      self.table_name = "lakeraven_ehr_smart_authorizations"

      CODE_LIFETIME = 2.minutes
      # The longest a launched token lives. Never past the session it is bound to.
      TOKEN_LIFETIME = 1.hour
      # RFC 7636 §4.1: 43 to 128 unreserved characters.
      CODE_VERIFIER = /\A[A-Za-z0-9\-._~]{43,128}\z/

      belongs_to :application, class_name: "Doorkeeper::Application"
      belongs_to :session_token, class_name: "Doorkeeper::AccessToken"
      belongs_to :access_token, class_name: "Doorkeeper::AccessToken", optional: true

      class << self
        # The authorization and its code. The code is returned once, here, and
        # never stored.
        def issue!(**attributes)
          code = SecureRandom.urlsafe_base64(32)
          record = create!(**attributes, code_digest: digest(code), expires_at: CODE_LIFETIME.from_now)
          [ record, code ]
        end

        def find_by_code(code)
          return nil unless code.is_a?(String) && code.present?

          find_by(code_digest: digest(code))
        end

        # The authorization a launched token was issued from, or nil for any
        # other token (a browser session's, a backend client's).
        def for_access_token(token)
          return nil if token.nil?

          find_by(access_token_id: token.id)
        end

        def digest(code) = Digest::SHA256.hexdigest(code)
      end

      def expired? = expires_at <= Time.current

      def redeemed? = redeemed_at.present?

      # RFC 7636 S256: the verifier hashes to the challenge sent at authorize.
      # No verifier, a blank one or a malformed one never matches.
      def pkce_verified?(verifier)
        return false unless verifier.is_a?(String) && verifier.match?(CODE_VERIFIER)

        expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        ActiveSupport::SecurityUtils.secure_compare(expected, code_challenge)
      end

      # The browser session this was approved in still stands: its token is
      # neither revoked nor expired. Every way a session ends revokes it.
      def session_live?
        token = session_token
        token.present? && !token.revoked? && !token.expired?
      end

      # The session stands, and so does its RPMS connection, where this process
      # holds per-user connections (RpmsSessions). A connection released at
      # its idle limit or dropped by the broker is not reopened: the app keeps
      # no codes, so the user signs in again and the app is launched again.
      def binding_live?
        return false unless session_live?
        return true unless RpmsSessions.enabled?

        RpmsSessions.live?(pool_key)
      end

      # The pool key of the user's own RPMS connection: the session's.
      def pool_key = RpmsSessions.key_for(session_token)

      # Mark the code used. False when another request used it first.
      def redeem!
        self.class.where(id: id, redeemed_at: nil).update_all(redeemed_at: Time.current) == 1
      end

      # A used code presented again: whoever holds it, the token it bought is
      # no longer trusted (RFC 6749 §4.1.2).
      def revoke_issued_token!
        access_token.revoke if access_token && !access_token.revoked?
      end

      # The token the code buys. A patient-context token names its patient as
      # the resource owner, which is what binds it to that patient's compartment
      # (SmartAuthentication#authorize_patient_context!). The user's DUZ stays
      # here, never in the token's resource owner, so the two namespaces never
      # share a column.
      def issue_access_token!
        token = Doorkeeper::AccessToken.create!(
          application: application,
          scopes: scopes,
          resource_owner_id: patient_dfn.presence&.to_i,
          expires_in: token_lifetime
        )
        update!(access_token: token)
        token
      end

      # TOKEN_LIFETIME, or what is left of the session when that is less.
      def token_lifetime
        return TOKEN_LIFETIME.to_i if session_token.expires_in.nil?

        remaining = (session_token.created_at + session_token.expires_in.seconds - Time.current).to_i
        [ TOKEN_LIFETIME.to_i, remaining ].min
      end
    end
  end
end
