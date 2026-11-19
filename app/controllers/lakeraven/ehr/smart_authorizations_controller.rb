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
    # The launch's patient comes from an EHR launch's context (smart/launch,
    # the `launch` parameter), or, for a standalone launch that asks for
    # `launch/patient`, from the user choosing one with the chart's own patient
    # search. patient/ scopes are granted only once there is a patient.
    #
    # Errors that make the app or its redirect URI untrustworthy (an unknown
    # client, an unregistered redirect URI, a wrong `aud`) are shown here and
    # never sent back: a redirect would hand a code or an error to an address
    # nobody vouched for, or to an app that asked about another server. Every
    # other error goes back to the app, with its `state`, as OAuth says.
    class SmartAuthorizationsController < WebController
      # SMART App Launch is how an app gets a patient token: fhir_api (#970).
      include DisclosureSurfaceGate
      disclosure_surface :fhir_api
      include SmartEndpoints

      # The approve screen and its patient picker sit behind sign-in; a code
      # guesser reaches them through the same identity (#498).
      rate_limit only: %i[show decide patient choose_patient new]

      PENDING = :smart_authorization_request
      REQUEST_PARAMS = %w[
        response_type client_id redirect_uri scope state aud code_challenge code_challenge_method launch
      ].freeze
      DFN = /\A\d{1,18}\z/

      before_action :require_authentication, only: %i[show decide patient choose_patient]
      before_action :load_pending, only: %i[show decide patient choose_patient]

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
        # An EHR launch (smart/launch) names its context: one this server
        # minted, for this app, not yet used or expired.
        if request_params["launch"].present? && LaunchContext.resolve(request_params["launch"])&.oauth_application_uid != app.uid
          return redirect_with_error(request_params, "invalid_request", "The launch is unknown or has expired.")
        end

        end_stale_session!
        session[PENDING] = request_params
        return redirect_to(smart_authorization_approval_path) if session[:duz].present?

        flash[:notice] = "Sign in with your RPMS access and verify codes to continue to #{app.name}."
        redirect_to login_path
      end

      # GET /oauth/authorize/approval: what the app asked for, in plain words.
      def show
        return redirect_to(smart_authorization_patient_path) if patient_to_choose?

        @patient = ChartSearchGateway.one(launch_patient_dfn) if launch_patient_dfn
        @scopes = granted_scopes
        render :show
      rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
        lookup_failed(e)
      end

      # GET /oauth/authorize/patient: a standalone launch asked for a patient
      # (launch/patient), so the user chooses one, the way they find a chart.
      def patient
        @matches = []
        render :patient
      end

      # POST /oauth/authorize/patient: a search (q), or the patient chosen
      # (dfn). Posted, so what was typed never rides in a URL (#722).
      def choose_patient
        return choose(params[:dfn].to_s) if params[:dfn].present?

        @query = params[:q].to_s.strip
        @matches = @query.empty? ? [] : ChartSearchGateway.find(@query)
        render :patient
      rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
        lookup_failed(e)
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
          rpms_idle_seconds: session[:rpms_idle_seconds],
          patient_dfn: launch_patient_dfn,
          encounter_id: @launch_context&.encounter_id.presence,
          # Apps open in their own window, never inside this one, so the app
          # shows who the patient is.
          need_patient_banner: launch_patient_dfn.present?
        )
        @launch_context&.destroy # a launch is used once
        redirect_to redirect_uri_with(@pending["redirect_uri"], code: code, state: @pending["state"]), allow_other_host: true
      end

      private

      def load_pending
        @pending = session[PENDING]
        @app = launch_client(@pending&.dig("client_id"))
        unless @pending.present? && @app
          session.delete(PENDING)
          return render_refusal(:no_request)
        end
        return if @pending["launch"].blank?

        # An EHR launch is the launching user's alone.
        @launch_context = LaunchContext.resolve(@pending["launch"])
        return if @launch_context && @launch_context.oauth_application_uid == @app.uid &&
                  @launch_context.duz.to_s == session[:duz].to_s

        session.delete(PENDING)
        render_refusal(:launch_ended)
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

      # The patient the launch is about: the EHR launch's, or the one the user
      # chose for a standalone launch.
      def launch_patient_dfn
        @launch_context&.patient_dfn.presence || @pending["patient_dfn"].presence
      end

      def requested_scopes = @pending["scope"].to_s.split

      # A standalone launch asked for a patient, none is chosen yet, and the
      # user can search patients at all (otherwise no patient/ scope is granted).
      def patient_to_choose?
        requested_scopes.include?("launch/patient") && launch_patient_dfn.blank? &&
          SmartScope.permits?(session_token_scopes, "Patient", "s")
      end

      # The chosen patient, if RPMS knows them, becomes the launch's patient.
      def choose(dfn)
        chosen = ChartSearchGateway.one(dfn) if dfn.match?(DFN)
        return render_refusal(:no_patient) unless chosen

        session[PENDING] = @pending.merge("patient_dfn" => chosen.dfn.to_s)
        redirect_to smart_authorization_approval_path
      end

      # Clinical scopes (LaunchScopePolicy): patient/ ones only once there is a
      # patient. Then the launch scopes the app asked for and got: `launch`
      # for an EHR launch, `launch/patient` for a launch with a patient.
      def granted_scopes
        clinical = LaunchScopePolicy.new(
          requested: @pending["scope"],
          registered: @app.scopes.to_s,
          user_scopes: session_token_scopes,
          contexts: launch_patient_dfn ? %w[user patient] : %w[user]
        ).granted
        return clinical if clinical.empty?

        launch = []
        launch << "launch" if @launch_context && requested_scopes.include?("launch")
        launch << "launch/patient" if launch_patient_dfn && requested_scopes.include?("launch/patient")
        launch + clinical
      end

      def session_token_scopes
        Doorkeeper::AccessToken.by_token(session[:smart_token].to_s)&.scopes.to_s
      end

      def lookup_failed(error)
        return end_session_for_closed_rpms! if rpms_connection_closed?

        Rails.logger.error("[smart-authorize] patient lookup failed: #{error.class}")
        @lookup_failed = true
        @matches = []
        render :patient, status: :service_unavailable
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
