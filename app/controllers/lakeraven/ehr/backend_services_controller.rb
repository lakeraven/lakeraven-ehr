# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART Backend Services OAuth token endpoint.
    # ONC 170.315(g)(10)(vi); Vardana source-system profile section 2.
    #
    # client_credentials grant, client authenticated by a JWT assertion
    # (private_key_jwt) signed with a key from the JWKS the client publishes
    # at its registered jwks_uri. Issued tokens are short-lived and carry
    # only system/ scopes within the client's registration; the client's
    # organization binding (organization_id) scopes all FHIR reads made with
    # the token to that organization's patients.
    class BackendServicesController < ActionController::API
      CLIENT_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
      ALLOWED_ALGORITHMS = %w[RS384 RS256 ES384].freeze
      TOKEN_LIFETIME = 5.minutes
      # SMART Backend Services: assertion exp SHALL be no more than five
      # minutes in the future (small allowance for clock skew).
      MAX_ASSERTION_LIFETIME = 5.minutes + 30.seconds

      def token
        unless params[:grant_type] == "client_credentials"
          return render_token_error("unsupported_grant_type", status: :bad_request)
        end

        unless params[:client_assertion_type] == CLIENT_ASSERTION_TYPE
          return render_token_error("invalid_request",
            description: "client_assertion_type must be #{CLIENT_ASSERTION_TYPE}",
            status: :bad_request)
        end

        assertion = params[:client_assertion]
        unless assertion.present?
          return render_token_error("invalid_client",
            description: "client_assertion is required", status: :bad_request)
        end

        app = client_for(assertion)
        unless app
          return render_token_error("invalid_client",
            description: "Unknown client", status: :unauthorized)
        end

        claims = verify_assertion!(assertion, app)
        return unless claims

        scopes = granted_scopes(app)
        if scopes.empty?
          return render_token_error("invalid_scope",
            description: "No requested scope is within the client's registration",
            status: :bad_request)
        end

        access_token = Doorkeeper::AccessToken.create!(
          application: app,
          scopes: scopes.join(" "),
          expires_in: TOKEN_LIFETIME.to_i
        )

        render json: {
          access_token: access_token.plaintext_token || access_token.token,
          token_type: "bearer",
          expires_in: TOKEN_LIFETIME.to_i,
          scope: access_token.scopes.to_s
        }, status: :ok
      end

      private

      # Locate the client from the assertion's (unverified) iss claim; the
      # signature is then verified against that client's published JWKS.
      def client_for(assertion)
        unverified, = JWT.decode(assertion, nil, false)
        Doorkeeper::Application.find_by(uid: unverified["iss"])
      rescue JWT::DecodeError
        nil
      end

      # Verifies signature (against the client's published JWKS), aud, exp,
      # iss/sub consistency, and jti uniqueness. Renders the token error and
      # returns nil on any failure.
      def verify_assertion!(assertion, app)
        jwks = ClientJwks.fetch(app.jwks_uri)
        unless jwks
          return render_invalid_client("Client has no retrievable registered JWKS")
        end

        claims, = JWT.decode(
          assertion, nil, true,
          algorithms: ALLOWED_ALGORITHMS,
          jwks: JWT::JWK::Set.new(jwks),
          verify_aud: true,
          aud: token_endpoint_url
        )

        unless claims["iss"] == app.uid && claims["sub"] == app.uid
          return render_invalid_client("Assertion iss/sub must match the client id")
        end

        exp = claims["exp"].to_i
        if exp > MAX_ASSERTION_LIFETIME.from_now.to_i
          return render_invalid_client("Assertion exp too far in the future")
        end

        jti = claims["jti"].to_s
        return render_invalid_client("Assertion jti is required") if jti.blank?
        if AssertionReplayGuard.replayed?(app.uid, jti, exp)
          return render_invalid_client("Assertion has already been used")
        end

        claims
      rescue JWT::ExpiredSignature
        render_invalid_client("Assertion has expired")
      rescue JWT::InvalidAudError
        render_invalid_client("Assertion audience does not match the token endpoint")
      rescue JWT::DecodeError
        render_invalid_client("Invalid JWT assertion")
      end

      # Grant the intersection of the requested scopes and the client's
      # registered scopes, restricted to system/ scopes. A registered
      # wildcard (system/*.read) covers per-resource requests
      # (system/Patient.read); the reverse is not true.
      def granted_scopes(app)
        registered = app.scopes.to_s.split
        requested = (params[:scope].presence || app.scopes.to_s).split

        requested.uniq.select do |scope|
          scope.start_with?("system/") && scope_registered?(scope, registered)
        end
      end

      def scope_registered?(scope, registered)
        return true if registered.include?(scope) || registered.include?("system/*.*")

        if (match = scope.match(%r{\Asystem/[^.]+\.(read|write)\z}))
          registered.include?("system/*.#{match[1]}")
        else
          false
        end
      end

      def token_endpoint_url
        request.base_url + request.path
      end

      def render_invalid_client(description)
        render_token_error("invalid_client", description: description, status: :unauthorized)
        nil
      end

      def render_token_error(error, description: nil, status:)
        render json: { error: error, error_description: description }.compact, status: status
      end
    end
  end
end
