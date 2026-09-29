# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART Backend Services OAuth token endpoint.
    # ONC 170.315(g)(10)(vi); partner source-system profile section 2.
    #
    # client_credentials grant, client authenticated by a JWT assertion
    # (private_key_jwt) signed with a key from the JWKS the client publishes
    # at its registered jwks_uri. Issued tokens are short-lived and carry
    # only system/ scopes within the client's registration.
    #
    # organization_id is required before a token is minted: a client with a
    # blank binding is refused. Nothing in the FHIR read path consults that
    # column, so a token for organization A can still read organization B's
    # patients. Closing that gap is lakeraven-ehr#553.
    class BackendServicesController < ActionController::API
      CLIENT_ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
      # SMART Backend Services requires the authentication JWT to be signed
      # with RS384 and requires the authorization server to reject every
      # other alg. One algorithm, not a menu: RS256 is a different signature,
      # and ES384 is only optional in the spec, so an EC key in a published
      # JWKS cannot authenticate. HMAC and "none" are absent so the assertion
      # cannot choose a symmetric or unsigned algorithm.
      ALLOWED_ALGORITHMS = %w[RS384].freeze
      TOKEN_LIFETIME = 5.minutes
      # SMART Backend Services: assertion exp SHALL be no more than five
      # minutes in the future — a hard cap, with no skew allowance on top
      # (an earlier +30s allowance exceeded the spec ceiling).
      MAX_ASSERTION_LIFETIME = 5.minutes
      # Every claim the verifier relies on must be present; JWT.decode
      # otherwise treats a MISSING exp as "never expires" (nil.to_i == 0
      # passes the max-lifetime check), yielding a replayable assertion.
      REQUIRED_CLAIMS = %w[iss sub aud exp jti].freeze

      def token
        unless params[:grant_type] == "client_credentials"
          return render_token_error("unsupported_grant_type", status: :bad_request)
        end

        unless params[:client_assertion_type] == CLIENT_ASSERTION_TYPE
          return render_token_error("invalid_request",
            description: "client_assertion_type must be #{CLIENT_ASSERTION_TYPE}",
            status: :bad_request)
        end

        assertion = require_client_assertion
        return unless assertion

        app = client_for(assertion)
        unless app
          return render_invalid_client("unknown_client")
        end

        claims = verify_assertion!(assertion, app)
        return unless claims

        # Mint-time gate only. A blank organization_id is not issued a
        # system/ token. FHIR reads do not apply the binding, so this does
        # not stop a token for organization A from reading organization B
        # (lakeraven-ehr#553).
        if app.organization_id.blank?
          return render_invalid_client("client_not_bound_to_organization")
        end

        # SINGLE-ORGANIZATION GUARD (lakeraven-ehr#553).
        #
        # The binding above is recorded and NOT enforced on reads, so a
        # system/ token for organization A can read organization B's
        # patients. That is currently unreachable for a structural reason
        # rather than a policy one: RpmsRpc.client is a single process-global
        # broker connection (rpms-rpc#234), so one deployment reaches exactly
        # one RPMS, and one RPMS serves one tribe. One deployment therefore
        # holds one organization.
        #
        # That is an accident of the transport, not a control, and #234 ends
        # it: per-session or pooled connections let one deployment serve
        # several RPMS instances. Rather than leave the safety of this surface
        # resting on an unenforced assumption, refuse to mint once a second
        # distinct organization appears. The build fails loudly at the moment
        # the assumption stops holding instead of silently leaking across
        # tribes.
        #
        # Remove this guard when #553 scopes reads by organization.
        if other_organization_registered?(app)
          return render_invalid_client("multiple_organizations_unsupported")
        end

        return unless scope_param_usable?

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
        return nil unless assertion.is_a?(String)

        unverified, = JWT.decode(assertion, nil, false)
        Doorkeeper::Application.find_by(uid: unverified["iss"])
      rescue JWT::DecodeError
        nil
      end

      # Verifies signature (against the client's published JWKS), aud, exp,
      # iss/sub consistency, and jti uniqueness. Renders the token error and
      # returns nil on any failure.
      def verify_assertion!(assertion, app)
        return render_invalid_client("undecodable") unless assertion.is_a?(String)

        jwks = ClientJwks.fetch(app.jwks_uri)
        unless jwks
          return render_invalid_client("no_retrievable_jwks")
        end

        claims, = JWT.decode(
          assertion, nil, true,
          algorithms: ALLOWED_ALGORITHMS,
          jwks: JWT::JWK::Set.new(jwks),
          verify_aud: true,
          aud: token_endpoint_url,
          required_claims: REQUIRED_CLAIMS
        )

        unless claims["iss"] == app.uid && claims["sub"] == app.uid
          return render_invalid_client("iss_sub_mismatch")
        end

        exp = claims["exp"].to_i
        if exp > MAX_ASSERTION_LIFETIME.from_now.to_i
          return render_invalid_client("exp_too_far")
        end
        if claims["iat"].present? && exp - claims["iat"].to_i > MAX_ASSERTION_LIFETIME.to_i
          return render_invalid_client("lifetime_too_long")
        end

        jti = claims["jti"].to_s
        return render_invalid_client("missing_jti") if jti.blank?
        if AssertionReplayGuard.replayed?(app.uid, jti, exp)
          return render_invalid_client("replayed_jti")
        end

        claims
      rescue JWT::ExpiredSignature
        render_invalid_client("expired")
      rescue JWT::InvalidAudError
        render_invalid_client("bad_audience")
      rescue JWT::DecodeError
        render_invalid_client("undecodable")
      end

      # Grant the intersection of the requested scopes and the client's
      # registered scopes, restricted to system/ scopes. A registered
      # wildcard (system/*.read) covers per-resource requests
      # (system/Patient.read); the reverse is not true.
      def granted_scopes(app)
        registered = app.scopes.to_s.split
        requested = requested_scope_values(app)

        requested.uniq.select do |scope|
          scope.start_with?("system/") && scope_registered?(scope, registered)
        end
      end

      # A non-string scope (scope[]=system/Patient.read arrives as an Array)
      # has no #split, so calling it is an HTTP 500. Treating it as omitted
      # would grant every registered scope. Empty is not a grant.
      def requested_scope_values(app)
        raw = params[:scope]
        return [] unless raw.nil? || raw.is_a?(String)

        (raw.presence || app.scopes.to_s).split
      end

      def scope_registered?(scope, registered)
        return true if registered.include?(scope) || registered.include?("system/*.*")

        if (match = scope.match(%r{\Asystem/[^.]+\.(read|write)\z}))
          registered.include?("system/*.#{match[1]}")
        else
          false
        end
      end

      # The expected assertion audience. When the deployment configures its
      # published token endpoint URL (the value .well-known/smart-configuration
      # advertises), that is the ONLY accepted audience — never the incoming
      # request's Host, which a reverse proxy rewrites and a cross-host replay
      # controls. The request-derived value is only a fallback for
      # unconfigured (dev/test) deployments.
      def token_endpoint_url
        Lakeraven::EHR.configuration.token_endpoint_url.presence ||
          request.base_url + request.path
      end

      # Every client-authentication refusal looks identical from outside.
      #
      # The per-reason description was a registry oracle: an unauthenticated
      # caller could distinguish an unknown client from a registered one with
      # no retrievable JWKS from a genuine signature failure, and could do so
      # before presenting any valid signature. The specific reason is still
      # recorded — it is the most useful thing in the log, because a run of
      # refusals is what probing looks like — but it does not travel back to
      # the caller.
      UNIFORM_REFUSAL = "Client authentication failed"

      # nil and a blank string are a missing assertion (invalid_client).
      # Any other non-string — client_assertion[]=... arrives as an Array —
      # is a malformed request. JWT.decode raises ArgumentError on an Array,
      # which is not a DecodeError and would otherwise be an HTTP 500.
      def require_client_assertion
        assertion = params[:client_assertion]
        if assertion.is_a?(String)
          return assertion if assertion.present?

          render_token_error("invalid_client",
            description: "client_assertion is required", status: :bad_request)
          return
        end

        if assertion.nil?
          render_token_error("invalid_client",
            description: "client_assertion is required", status: :bad_request)
        else
          render_token_error("invalid_request",
            description: "client_assertion must be a string",
            status: :bad_request)
        end
        nil
      end

      def scope_param_usable?
        raw = params[:scope]
        return true if raw.nil? || raw.is_a?(String)

        render_token_error("invalid_request",
          description: "scope must be a string",
          status: :bad_request)
        false
      end

      def render_invalid_client(reason)
        Rails.logger.info("[backend_services] refused: #{reason}")
        render_token_error("invalid_client", description: UNIFORM_REFUSAL, status: :unauthorized)
        nil
      end

      def render_token_error(error, description: nil, status:)
        render json: { error: error, error_description: description }.compact, status: status
      end

      # True when another registered client is bound to a genuinely different
      # organization. Reads through Doorkeeper's application model so a client
      # registered by any path is counted, not just ones minted here.
      #
      # Compared NORMALISED (strip + casefold). organization_id is a free-form
      # string column, not a verified RPMS binding, so "Example-Org" and
      # "example-org " are the same site written twice. Comparing raw would
      # let a formatting variant shut off token issuance for a deployment
      # that still serves exactly one RPMS — trading a confidentiality risk
      # for an availability one (review finding on this PR).
      #
      # The refusal is still deliberate where the difference is real: reads
      # are not organization-scoped (#553), so once two organizations exist
      # EVERY system/ token is effectively global and refusing both is the
      # conservative choice. Backend-services tokens are system-to-system;
      # user-facing sessions are unaffected.
      def other_organization_registered?(app)
        mine = normalized_organization(app.organization_id)
        return false if mine.blank?

        Doorkeeper::Application
          .where.not(organization_id: [ nil, "" ])
          .pluck(:organization_id)
          .any? { |other| normalized_organization(other) != mine }
      end

      def normalized_organization(value)
        value.to_s.strip.downcase
      end
    end
  end
end
