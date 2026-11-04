# frozen_string_literal: true

module Lakeraven
  module EHR
    # The SMART App Launch authorization endpoint (#839): an app sends the
    # user here, the user signs in with their own RPMS access and verify codes
    # (the ordinary sign-in, ADR 0011), sees what the app asked for in plain
    # words, and approves or denies. On approval the app gets a one-time code
    # (SmartAuthorization) it swaps at the token endpoint (SmartTokensController).
    #
    # Accepts GET and POST (SMART's authorize-post). The request is checked,
    # then kept in the session while the user signs in and decides, so nothing
    # the app sent rides through the sign-in form or the approval form.
    #
    # Errors that make the app or its redirect URI untrustworthy (an unknown
    # client, an unregistered redirect URI, a wrong `aud`) are shown here and
    # never sent back: a redirect would hand a code or an error to an address
    # nobody vouched for, or to an app that asked about another server. Every
    # other error goes back to the app, with its `state`, as OAuth says.
    class SmartAuthorizationsController < WebController
      include SmartEndpoints

      PENDING = :smart_authorization_request
      REQUEST_PARAMS = %w[response_type client_id redirect_uri scope state aud code_challenge code_challenge_method].freeze

      before_action :require_authentication, only: %i[show decide]
      before_action :load_pending, only: %i[show decide]

      # An app's page posts here from another site, and a SameSite=Lax session
      # cookie does not ride a cross-site POST. Answering it would sign a
      # signed-in user out (a new session cookie over theirs), so a POST is
      # turned into the same request as a GET, which the cookie does ride. It
      # changes nothing, so it needs no forgery token. The values are the
      # app's own request (client, scopes, state, PKCE challenge): no PHI.
      skip_forgery_protection only: :new

      # GET or POST /oauth/authorize
      def new
        if request.post?
          return redirect_to(smart_authorization_path(params.permit(*REQUEST_PARAMS).to_h), status: :see_other)
        end

        request_params = REQUEST_PARAMS.index_with { |name| string_param(name) }
        app = launch_client(request_params["client_id"])
        return render_refusal(:unknown_client) unless app
        return render_refusal(:unregistered_redirect) unless redirect_registered?(app, request_params["redirect_uri"])
        return render_refusal(:wrong_server) unless aud_names_this_server?(request_params["aud"])

        unless request_params["response_type"] == "code"
          return redirect_with_error(request_params, "unsupported_response_type", "Only the authorization code flow is served.")
        end
        if request_params["code_challenge"].blank? || request_params["code_challenge_method"] != "S256"
          return redirect_with_error(request_params, "invalid_request", "PKCE with code_challenge_method S256 is required.")
        end

        end_stale_session!
        session[PENDING] = request_params
        return redirect_to(smart_authorization_approval_path) if session[:duz].present?

        flash[:notice] = "Sign in with your RPMS access and verify codes to continue to #{app.name}."
        redirect_to login_path
      end

      # GET /oauth/authorize/approval: what the app asked for, in plain words.
      def show
        @scopes = granted_scopes
        render :show
      end

      # POST /oauth/authorize/approval
      def decide
        session.delete(PENDING)
        return redirect_with_error(@pending, "access_denied", "The user denied the request.") unless params[:decision] == "approve"

        scopes = granted_scopes
        return redirect_with_error(@pending, "invalid_scope", "Nothing the app asked for can be granted.") if scopes.empty?

        session_token = Doorkeeper::AccessToken.by_token(session[:smart_token].to_s)
        return redirect_with_error(@pending, "access_denied", "The sign-in session has ended.") unless session_token

        _authorization, code = SmartAuthorization.issue!(
          application: @app,
          redirect_uri: @pending["redirect_uri"],
          code_challenge: @pending["code_challenge"],
          scopes: scopes.join(" "),
          session_token: session_token,
          duz: session[:duz].to_s,
          user_name: session[:user_name],
          rpms_session_id: session[:rpms_session_id],
          rpms_idle_seconds: session[:rpms_idle_seconds]
        )
        redirect_to redirect_uri_with(@pending["redirect_uri"], code: code, state: @pending["state"]), allow_other_host: true
      end

      private

      def load_pending
        @pending = session[PENDING]
        @app = launch_client(@pending&.dig("client_id"))
        return if @pending.present? && @app

        session.delete(PENDING)
        render_refusal(:no_request)
      end

      # A client registered to launch (LaunchClient): public, or confidential
      # with a client secret or a published key set.
      def launch_client(client_id) = LaunchClient.find(client_id)

      # Exact match against one of the registered redirect URIs.
      def redirect_registered?(app, redirect_uri)
        redirect_uri.present? && app.redirect_uri.to_s.split.include?(redirect_uri)
      end

      def aud_names_this_server?(aud)
        aud.present? && aud.chomp("/") == smart_fhir_base_url
      end

      def granted_scopes
        LaunchScopePolicy.new(
          requested: @pending["scope"],
          registered: @app.scopes.to_s,
          user_scopes: Doorkeeper::AccessToken.by_token(session[:smart_token].to_s)&.scopes.to_s
        ).granted
      end

      # A session that has idled out, outlived its lifetime, lost its token or
      # its RPMS connection ends now, so the pending request is kept in a fresh
      # session and the user signs in again.
      def end_stale_session!
        return if session[:duz].blank?
        return unless session_idle_expired? || session_lifetime_expired? || session_token_revoked? || rpms_connection_closed?

        terminate_session!
      end

      def string_param(name)
        value = params[name]
        value.is_a?(String) ? value : nil
      end

      def redirect_with_error(request_params, error, description)
        redirect_to redirect_uri_with(request_params["redirect_uri"],
          error: error, error_description: description, state: request_params["state"]), allow_other_host: true
      end

      def redirect_uri_with(base, **values)
        uri = URI.parse(base)
        query = URI.decode_www_form(uri.query.to_s) + values.compact.map { |k, v| [ k.to_s, v.to_s ] }
        uri.query = URI.encode_www_form(query)
        uri.to_s
      end

      def render_refusal(reason)
        note_audit_denial("smart authorize refused: #{reason}")
        @reason = reason
        render :refused, status: :bad_request
      end
    end
  end
end
