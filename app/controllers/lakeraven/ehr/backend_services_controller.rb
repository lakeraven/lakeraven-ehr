# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART Backend Services OAuth token endpoint
    # ONC 170.315(g)(10)(vi) - Backend services authorization
    #
    # RFC 7523 client authentication: the client proves itself with a JWT it
    # SIGNED. Decoding the payload is not authentication — before #496 this
    # endpoint split the assertion on ".", read `iss` out of the payload, and
    # issued whatever scope the caller asked for. Anyone who could reach it
    # could mint any scope in the system, which made every scope-based control
    # elsewhere decorative. Each guard below exists because its absence was
    # exploitable.
    class BackendServicesController < ActionController::API
      # Signature algorithms accepted. "none" is deliberately absent: an
      # unsigned assertion is an unauthenticated one.
      #
      # Defence in depth, not the load-bearing control — verified by mutation:
      # adding "none" here alone changes no test outcome, because an alg-none
      # assertion carries no valid RSA signature and is refused by
      # #signature_valid? regardless. The allowlist exists so the refusal is
      # explicit and near the top, rather than incidental to crypto.
      PERMITTED_ALGORITHMS = %w[RS256 RS384 RS512].freeze

      # A jti may not be reused inside its own lifetime. Held for longer than
      # the maximum assertion lifetime so a replay cannot outlive the record.
      JTI_RETENTION = 10.minutes

      # RFC 7523 caps assertion lifetime; a long-lived assertion is a bearer
      # credential in all but name.
      MAX_ASSERTION_LIFETIME = 5.minutes

      def token
        unless params[:grant_type] == "client_credentials"
          render json: { error: "unsupported_grant_type" }, status: :bad_request
          return
        end

        if params[:client_assertion].blank?
          render json: { error: "invalid_client", error_description: "client_assertion is required" },
                 status: :bad_request
          return
        end

        result = authenticate_assertion(params[:client_assertion])
        unless result[:app]
          audit_token_event(outcome: "refused", reason: result[:reason])
          render json: { error: "invalid_client", error_description: result[:description] },
                 status: :unauthorized
          return
        end

        app = result[:app]
        granted = granted_scopes(app, params[:scope])

        if granted.empty?
          audit_token_event(outcome: "refused", reason: "no_permitted_scope", application: app)
          render json: { error: "invalid_scope",
                         error_description: "No requested scope is registered to this client" },
                 status: :bad_request
          return
        end

        access_token = Doorkeeper::AccessToken.create!(
          application: app,
          scopes: granted.join(" "),
          expires_in: 3600
        )
        audit_token_event(outcome: "issued", application: app, scopes: granted)

        render json: {
          access_token: access_token.plaintext_token || access_token.token,
          token_type: "bearer",
          expires_in: 3600,
          scope: access_token.scopes.to_s
        }, status: :ok
      end

      private

      # Returns {app:} on success, or {reason:, description:} on refusal.
      # Fails closed: every path that is not a verified assertion from a
      # registered client with a registered key returns no app.
      def authenticate_assertion(assertion)
        segments = assertion.split(".", -1)
        unless segments.length == 3
          return refusal("malformed", "Assertion is not a three-segment JWT")
        end

        header = decode_segment(segments[0])
        payload = decode_segment(segments[1])
        return refusal("undecodable", "Assertion header or payload is not valid JSON") if header.nil? || payload.nil?

        alg = header["alg"]
        unless PERMITTED_ALGORITHMS.include?(alg)
          return refusal("unpermitted_alg", "Unsupported assertion algorithm")
        end

        # iss identifies the client; sub must be the same client (RFC 7523 §3).
        # Checked before any lookup so a mismatched pair never selects an app.
        issuer = payload["iss"].to_s
        return refusal("iss_sub_mismatch", "iss and sub must be the client id") if issuer.empty? || payload["sub"].to_s != issuer

        unless audience_valid?(payload["aud"])
          return refusal("bad_audience", "aud must be this token endpoint")
        end

        expiry = payload["exp"]
        return refusal("missing_exp", "exp is required") unless expiry.is_a?(Integer)

        now = Time.current.to_i
        return refusal("expired", "Assertion has expired") if expiry <= now
        return refusal("lifetime_too_long", "Assertion lifetime exceeds the permitted maximum") if expiry - now > MAX_ASSERTION_LIFETIME.to_i

        jti = payload["jti"].to_s
        return refusal("missing_jti", "jti is required") if jti.empty?

        app = Doorkeeper::Application.find_by(uid: issuer)
        return refusal("unknown_client", "Unknown client") unless app

        public_key = registered_key(app)
        return refusal("no_registered_key", "Client has no registered public key") unless public_key

        unless signature_valid?(public_key, alg, segments)
          return refusal("bad_signature", "Assertion signature does not verify")
        end

        # Replay is checked LAST, so a rejected assertion cannot burn a jti and
        # a replay check cannot be used to probe which clients exist.
        return refusal("replayed_jti", "Assertion jti has already been used") unless claim_jti(issuer, jti, expiry)

        { app: app }
      end

      def refusal(reason, description)
        { app: nil, reason: reason, description: description }
      end

      def decode_segment(segment)
        JSON.parse(Base64.urlsafe_decode64(pad_base64(segment)))
      rescue ArgumentError, JSON::ParserError
        nil
      end

      def pad_base64(segment)
        segment + ("=" * ((4 - (segment.length % 4)) % 4))
      end

      def audience_valid?(aud)
        Array(aud).map(&:to_s).include?(token_endpoint_url)
      end

      def token_endpoint_url
        url_for(action: :token, only_path: false)
      end

      def registered_key(app)
        pem = app.respond_to?(:public_key) ? app.public_key : nil
        return nil if pem.blank?

        OpenSSL::PKey::RSA.new(pem)
      rescue OpenSSL::PKey::RSAError
        nil
      end

      def signature_valid?(public_key, alg, segments)
        digest = case alg
        when "RS256" then OpenSSL::Digest.new("SHA256")
        when "RS384" then OpenSSL::Digest.new("SHA384")
        when "RS512" then OpenSSL::Digest.new("SHA512")
        end
        signature = Base64.urlsafe_decode64(pad_base64(segments[2]))
        public_key.verify(digest, signature, "#{segments[0]}.#{segments[1]}")
      rescue ArgumentError, OpenSSL::PKey::PKeyError
        false
      end

      # True when this jti is newly claimed. Backed by a unique index rather
      # than a cache: a replay guard that disables itself when no cache is
      # configured fails open, which is the class of defect this endpoint is
      # being fixed for.
      def claim_jti(issuer, jti, expiry)
        BackendAssertionJti.purge_expired
        BackendAssertionJti.claim(issuer: issuer, jti: jti, expires_at: Time.zone.at(expiry))
      end

      # Every issuance and every refusal is recorded. A refusal is the event
      # most worth keeping: it is what probing looks like.
      def audit_token_event(outcome:, reason: nil, application: nil, scopes: nil)
        AuditEvent.create!(
          action: "backend_services_token",
          outcome: outcome,
          user_identifier: application&.uid || "unknown",
          resource_type: "OAuthToken",
          resource_id: reason || scopes&.join(" "),
          occurred_at: Time.current
        )
      rescue StandardError => e
        Rails.logger.warn("[backend_services] audit write failed: #{e.class}")
      end

      # Only scopes the application is registered for. A requested scope that
      # was never registered is dropped, never granted.
      def granted_scopes(app, requested)
        registered = app.scopes.to_s.split
        return [] if registered.empty?

        asked = requested.to_s.split
        return registered if asked.empty?

        asked & registered
      end
    end
  end
end
