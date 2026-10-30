# frozen_string_literal: true

module Lakeraven
  module EHR
    # Every request of a signed-in browser session runs on that user's own RPMS
    # connection (ADR 0011, RpmsSessions): inside RpmsRpc.with_client, every
    # gateway and gem call resolves RpmsRpc.client to that connection, and to
    # no other. Included by every controller that serves a signed-in browser
    # and reads RPMS: WebController and ChartsController.
    #
    # A session whose connection is gone (released at its idle limit, dropped
    # by the broker, or ended by its token's revocation) ends here, and its
    # user signs in again. A request with no connection of its own (a bearer
    # token, or no session) runs with none, so an RPMS call raises
    # RpmsRpc::NotConfiguredError rather than borrowing someone else's.
    module RpmsUserScope
      extend ActiveSupport::Concern

      included do
        around_action :run_on_users_rpms_connection
        rescue_from RpmsRpc::NotConfiguredError, with: :rpms_identity_missing
      end

      private

      def run_on_users_rpms_connection(&action)
        key = session[:rpms_pool_key]
        return action.call unless RpmsSessions.enabled? && key.present?
        return rpms_session_ended unless RpmsSessions.live?(key)

        RpmsSessions.with_user(key, &action)
      rescue RpmsSessions::SignInAgain, RpmsRpc::SessionPool::PoolExhaustedError
        rpms_session_ended
      end

      # The session's connection is gone: end the session, and sign in again.
      def rpms_session_ended
        end_rpms_session!
        if request.format.html?
          redirect_to login_path, alert: "Your RPMS session ended. Sign in again."
        else
          head :unauthorized
        end
      end

      # An RPMS call with no connection of its own: a bearer-token request, or
      # a session that has none. Never served on another user's connection.
      def rpms_identity_missing
        Rails.logger.warn("[rpms] request with no RPMS connection of its own: #{controller_path}##{action_name}")
        return rpms_session_ended if session[:duz].present?

        head :service_unavailable
      end

      # Release the connection, revoke the session's credential, and clear the
      # session. WebController's terminate_session! does all three.
      def end_rpms_session!
        return terminate_session! if respond_to?(:terminate_session!, true)

        RpmsSessions.release(session[:rpms_pool_key]) if RpmsSessions.enabled?
        revoke_session_smart_token! if respond_to?(:revoke_session_smart_token!, true)
        reset_session
      end
    end
  end
end
