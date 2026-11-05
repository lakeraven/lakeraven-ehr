# frozen_string_literal: true

module Lakeraven
  module EHR
    # The token endpoint's authorization_code grant (#839): a client swaps the
    # one-time code from SmartAuthorizationsController for an access token.
    # client_credentials stays BackendServicesController's; the route sends
    # each grant to its own controller.
    #
    # Refused, with nothing issued:
    #   - a client that does not authenticate as the one the code was issued to;
    #   - a code that is unknown, expired, already used, or for another
    #     redirect URI;
    #   - a code_verifier that is missing, blank, malformed, or does not hash to
    #     the S256 challenge sent at authorize (RFC 7636);
    #   - a code whose user has since signed out, timed out, or been signed in
    #     again elsewhere: the token would have no session to read RPMS on.
    # A used code presented again also revokes the token it bought.
    class SmartTokensController < ActionController::API
      include SmartEndpoints
      include RateLimitable

      # The token endpoint takes a client credential (#498).
      rate_limit only: :create

      UNIFORM_REFUSAL = "Client authentication failed"

      def create
        app = authenticated_client
        return render_invalid_client unless app

        authorization = SmartAuthorization.find_by_code(string_param(:code))
        return render_invalid_grant("unknown code") unless authorization && authorization.application_id == app.id

        if authorization.redeemed?
          authorization.revoke_issued_token!
          return render_invalid_grant("code already used")
        end
        return render_invalid_grant("code expired") if authorization.expired?
        return render_invalid_grant("redirect_uri does not match") unless string_param(:redirect_uri) == authorization.redirect_uri
        return render_invalid_grant("code_verifier does not match") unless authorization.pkce_verified?(string_param(:code_verifier))
        return render_invalid_grant("the user's session has ended") unless authorization.binding_live?
        return render_invalid_grant("code already used") unless authorization.redeem!

        token = authorization.issue_access_token!
        render_token(token, authorization)
      end

      private

      # The launch client this request authenticates as, by the way its
      # registration says it must (LaunchClient), or nil:
      #   - asymmetric: a client_assertion JWT signed with a key from its
      #     published JWKS (RS384 or ES384), the same checks as Backend
      #     Services (ClientAssertion);
      #   - symmetric: its client secret, by HTTP Basic or in the body
      #     (RFC 6749 §2.3.1); Basic wins when sent;
      #   - public: its client_id alone. PKCE is what proves it is the same
      #     client that started the flow.
      # A client presenting less than its registration requires is refused: a
      # confidential client cannot pass as a public one by leaving its secret off.
      def authenticated_client
        return asserted_client if params.key?(:client_assertion) || params.key?(:client_assertion_type)

        client_id, secret = client_credentials
        app = LaunchClient.find(client_id)
        return nil unless app

        case LaunchClient.kind(app)
        when :public then secret.blank? ? app : nil
        when :symmetric then secret.present? && app.secret_matches?(secret) ? app : nil
        end
      end

      def asserted_client
        return nil unless string_param(:client_assertion_type) == ClientAssertion::TYPE

        assertion = string_param(:client_assertion)
        app = ClientAssertion.claimed_client(assertion)
        return nil unless app && LaunchClient.launch_client?(app) && LaunchClient.kind(app) == :asymmetric
        return nil if string_param(:client_id).present? && string_param(:client_id) != app.uid

        ClientAssertion.new(assertion, app: app, audience: smart_token_endpoint,
          algorithms: LaunchClient::ASSERTION_ALGORITHMS).verify!
        app
      rescue ClientAssertion::Refused => e
        Rails.logger.info("[smart_token] client assertion refused: #{e.message}")
        nil
      end

      def client_credentials
        if request.authorization.to_s.match?(/\ABasic /i)
          user, password = ActionController::HttpAuthentication::Basic.user_name_and_password(request)
          return [ CGI.unescape(user.to_s), CGI.unescape(password.to_s) ]
        end

        [ string_param(:client_id), string_param(:client_secret) ]
      end

      # The token, and the launch context SMART asks for: the patient and
      # encounter when the launch has them, whether the app should show a
      # patient banner, and where this EHR's style is.
      def render_token(token, authorization)
        no_store!
        render json: {
          access_token: token.plaintext_token || token.token,
          token_type: "Bearer",
          expires_in: token.expires_in,
          scope: token.scopes.to_s,
          patient: authorization.patient_dfn.presence,
          encounter: authorization.encounter_id.presence,
          need_patient_banner: authorization.need_patient_banner,
          smart_style_url: "#{smart_fhir_base_url}/smart/style"
        }.compact, status: :ok
      end

      def string_param(name)
        value = params[name]
        value.is_a?(String) ? value : nil
      end

      # RFC 6749 §5.1: token responses, and their errors, are never cached.
      def no_store!
        response.headers["Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"
      end

      def render_invalid_client
        Rails.logger.info("[smart_token] refused: client authentication")
        no_store!
        response.headers["WWW-Authenticate"] = 'Basic realm="token"' if request.authorization.present?
        render json: { error: "invalid_client", error_description: UNIFORM_REFUSAL }, status: :unauthorized
      end

      def render_invalid_grant(reason)
        Rails.logger.info("[smart_token] refused: #{reason}")
        no_store!
        render json: { error: "invalid_grant", error_description: reason }, status: :bad_request
      end
    end
  end
end
