# frozen_string_literal: true

require "rpms_rpc/client"

module Lakeraven
  module EHR
    class SessionsController < WebController
      # Doorkeeper application every browser-session token belongs to. Named in
      # SmartAuthentication too — a token of this application is a browser
      # credential and is refused anywhere except the session that minted it.
      BROWSER_SSO_APP_NAME = SmartAuthentication::BROWSER_SSO_APP_NAME

      # How long a session may sit idle before it is signed out. RPMS sessions
      # are not 12-hour credentials and neither is this one; the token's own
      # expiry is the outer bound, this is the inner one.
      IDLE_TIMEOUT = SmartAuthentication::SESSION_IDLE_TIMEOUT
      TOKEN_LIFETIME = 12.hours

      def new
        # login form
      end

      # Real RPMS sign-on (#332, replacing the #401 canned interim): validate
      # the clinician's access/verify against RPMS, establish the browser
      # session, and mint a SMART token the API layer accepts via its session
      # fallback.
      def create
        access_code = params[:username].to_s

        if LoginThrottle.throttled?(access_code, request.remote_ip)
          # Refused BEFORE the credential is checked, and refused even when it
          # is correct: RPMS's own three-strike lock keys on the broker client
          # IP — the app server — so an unthrottled login route lets one
          # attacker lock out every clinician at once.
          return render_throttled
        end

        result = authenticate(access_code: access_code, verify_code: params[:password].to_s)

        return render_broker_unavailable if result.nil?
        return render_rejected(access_code, result.error) unless result.success?

        provider = result.value

        # A verify code RPMS has flagged for change is not a credential to
        # issue a 12-hour session against — CPRS forces the change first, and
        # so does this. Establishing no session is the fail-closed answer
        # until the change flow exists (#493 tracks building it).
        if provider[:verify_needs_change]
          reset_session
          flash.now[:alert] = "Your verify code must be changed before you can sign in."
          return render :new, status: :forbidden
        end

        LoginThrottle.clear(access_code, request.remote_ip)
        establish_session(provider)
        redirect_to dashboard_path
      end

      def destroy
        revoke_session_token!
        reset_session
        redirect_to login_path, notice: "Signed out"
      end

      private

      def authenticate(access_code:, verify_code:)
        AuthenticationService.new.authenticate(access_code: access_code, verify_code: verify_code)
      rescue RpmsRpc::Client::ConnectionError, RpmsRpc::NotConfiguredError, Errno::ECONNREFUSED,
             IOError, SocketError => e
        # A broker outage used to surface as an unhandled 500 whose exception
        # report carried the submitted parameters — including the access code.
        # Log the class, never the params.
        Rails.logger.error("RPMS sign-on unavailable: #{e.class}")
        nil
      end

      # A failed sign-on must not leave an earlier session standing. Deliberate
      # choice: the alternative (keep the existing session) means a walk-up
      # attacker's failed attempt leaves the previous clinician signed in on a
      # shared workstation, which is the situation this feature exists for.
      def render_rejected(access_code, _error)
        LoginThrottle.record_failure(access_code, request.remote_ip)
        revoke_session_token!
        reset_session
        # One message for every failure mode — no enumeration oracle.
        flash.now[:alert] = "Invalid username or password"
        render :new, status: :unprocessable_entity
      end

      def render_throttled
        response.headers["Retry-After"] = LoginThrottle.retry_after.to_s
        flash.now[:alert] = "Too many sign-in attempts. Try again later."
        render :new, status: :too_many_requests
      end

      def render_broker_unavailable
        reset_session
        flash.now[:alert] = "RPMS is not reachable right now. Try again shortly."
        render :new, status: :service_unavailable
      end

      def establish_session(provider)
        reset_session
        session[:duz] = provider[:duz]
        session[:user_name] = provider[:name]
        session[:user_type] = provider[:user_type].to_s
        session[:security_keys] = Array(provider[:security_keys]).map(&:to_s)
        session[:last_seen_at] = Time.current.to_i
        session[:smart_token] = mint_smart_token(provider)
      end

      # Mint a SMART token for this session, bound to the human and scoped by
      # what that human's RPMS security keys actually authorize.
      #
      # Two things this used to get wrong:
      #   * every session got `user/*.read user/*.write`, so a clerk with no
      #     security keys held the same credential as a physician;
      #   * the token was bound to nothing, so it worked from any session, or
      #     from none at all when replayed as a Bearer header.
      #
      # resource_owner_id carries the DUZ. SmartAuthentication only reads it as
      # a patient compartment for tokens carrying a `patient/` scope, and the
      # policy below never mints one — asserted here so the two meanings can
      # never collide silently.
      def mint_smart_token(provider)
        revoke_previous_tokens_for(provider[:duz])

        scopes = SessionScopePolicy.scope_string(
          security_keys: Array(provider[:security_keys]).map(&:to_sym)
        )
        raise "browser session tokens must never carry a patient/ scope" if scopes.include?("patient/")

        token = Doorkeeper::AccessToken.create!(
          application: browser_sso_application,
          scopes: scopes,
          resource_owner_id: provider[:duz].to_i,
          expires_in: TOKEN_LIFETIME.to_i
        )
        token.plaintext_token || token.token
      end

      # Signing in again is not a reason to leave the previous credential live:
      # three sign-ins used to leave three usable 12-hour tokens, none of them
      # revocable by the clinician who owned them. One human, one live browser
      # token — which also bounds the table's growth.
      def revoke_previous_tokens_for(duz)
        Doorkeeper::AccessToken
          .where(application_id: browser_sso_application.id, resource_owner_id: duz.to_i, revoked_at: nil)
          .find_each(&:revoke)
      end

      def browser_sso_application
        Doorkeeper::Application.find_or_create_by!(name: BROWSER_SSO_APP_NAME) do |a|
          a.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
          a.scopes = SessionScopePolicy.all_scopes.join(" ")
          a.confidential = true
        end
      end

      # Signing out revokes the credential, not just the cookie that carried
      # it. Clearing the session alone left a live 12-hour token behind — three
      # sign-ins left three of them, none revocable by the human who owned them.
      def revoke_session_token!
        raw = session[:smart_token].presence
        return if raw.nil?

        token = Doorkeeper::AccessToken.by_token(raw)
        token&.revoke unless token&.revoked?
      end
    end
  end
end
