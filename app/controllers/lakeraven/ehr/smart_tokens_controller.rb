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
        render_token(token)
      end

      private

      # A confidential client with a client secret: HTTP Basic, or client_id
      # and client_secret in the body (RFC 6749 §2.3.1). Basic wins when sent.
      def authenticated_client
        client_id, secret = client_credentials
        return nil if client_id.blank? || secret.blank?

        app = Doorkeeper::Application.find_by(uid: client_id)
        return nil unless app&.confidential? && app.jwks_uri.blank?

        app.secret_matches?(secret) ? app : nil
      end

      def client_credentials
        if request.authorization.to_s.match?(/\ABasic /i)
          user, password = ActionController::HttpAuthentication::Basic.user_name_and_password(request)
          return [ CGI.unescape(user.to_s), CGI.unescape(password.to_s) ]
        end

        [ string_param(:client_id), string_param(:client_secret) ]
      end

      def render_token(token)
        no_store!
        render json: {
          access_token: token.plaintext_token || token.token,
          token_type: "Bearer",
          expires_in: token.expires_in,
          scope: token.scopes.to_s
        }, status: :ok
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
