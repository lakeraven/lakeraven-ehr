# frozen_string_literal: true

module Lakeraven
  module EHR
    class SessionsController < WebController
      # Scopes granted to a signed-in clinician's browser session. The SMART
      # API layer (SmartAuthentication) already enforces these; the session just
      # carries a token it understands.
      SMART_SESSION_SCOPES = "user/*.read user/*.write"
      BROWSER_SSO_APP_NAME = "Lakeraven EHR Browser SSO"

      def new
        # login form
      end

      # Real RPMS sign-on (#332, replacing the #401 canned interim): validate the
      # clinician's access/verify against RPMS, establish the browser session,
      # and mint a SMART token the API layer accepts via its session fallback.
      def create
        result = AuthenticationService.new.authenticate(
          access_code: params[:username].to_s,
          verify_code: params[:password].to_s
        )

        unless result.success?
          flash.now[:alert] = "Invalid username or password"
          return render :new, status: :unprocessable_entity
        end

        establish_session(result.value)
        redirect_to dashboard_path
      end

      def destroy
        reset_session
        redirect_to login_path, notice: "Signed out"
      end

      private

      def establish_session(provider)
        reset_session
        session[:duz] = provider[:duz]
        session[:user_name] = provider[:name]
        session[:user_type] = provider[:user_type].to_s
        session[:security_keys] = Array(provider[:security_keys]).map(&:to_s)
        session[:smart_token] = mint_smart_token
      end

      # Mint a user-scoped SMART token for this session. DUZ is kept in the
      # session (not the token) to avoid overloading Doorkeeper's
      # resource_owner_id, which SmartAuthentication binds to patient dfn.
      def mint_smart_token
        app = Doorkeeper::Application.find_or_create_by!(name: BROWSER_SSO_APP_NAME) do |a|
          a.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
          a.scopes = SMART_SESSION_SCOPES
          a.confidential = true
        end

        token = Doorkeeper::AccessToken.create!(
          application: app,
          scopes: SMART_SESSION_SCOPES,
          expires_in: 12.hours.to_i
        )
        token.plaintext_token || token.token
      end
    end
  end
end
