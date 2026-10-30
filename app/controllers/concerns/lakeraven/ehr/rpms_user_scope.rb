# frozen_string_literal: true

module Lakeraven
  module EHR
    # Every browser request runs on its signed-in user's own RPMS connection
    # (ADR 0011, RpmsSessions): inside RpmsRpc.with_client, every gateway and
    # gem call resolves RpmsRpc.client to that connection, and to no other.
    # A request with no connection of its own (signed out, or not yet signed
    # in) runs with none, so any RPMS call it makes raises
    # RpmsRpc::NotConfiguredError rather than borrowing someone else's.
    # A connection the pool no longer holds sends the user to sign in again.
    module RpmsUserScope
      extend ActiveSupport::Concern

      included do
        around_action :run_on_users_rpms_connection
        rescue_from RpmsRpc::NotConfiguredError, with: :render_no_rpms_identity
      end

      private

      def run_on_users_rpms_connection(&action)
        key = session[:rpms_pool_key]
        return action.call unless RpmsSessions.enabled? && RpmsSessions.held?(key)

        RpmsSessions.with_user(key, &action)
      rescue RpmsSessions::SignInAgain
        end_session_for_closed_rpms!
      end

      def render_no_rpms_identity
        Rails.logger.error("[rpms] an RPMS call had no user connection: #{controller_path}##{action_name}")
        terminate_session!
        redirect_to login_path, alert: "Your RPMS session ended. Sign in again."
      end
    end
  end
end
