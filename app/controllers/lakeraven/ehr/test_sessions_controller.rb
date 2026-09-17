# frozen_string_literal: true

module Lakeraven
  module EHR
    # Test-only helper to seed Rails session for cucumber admin scenarios.
    # HARD-GATED to the test environment: this endpoint mints an arbitrary privileged
    # session (any DUZ + security keys) with no authentication, so it must never be
    # reachable outside tests. The controller-level gate makes a routes-file mistake
    # non-exploitable; the route should ALSO be mounted only inside `if Rails.env.test?`.
    class TestSessionsController < WebController
      before_action :ensure_test_environment!
      skip_before_action :verify_authenticity_token, raise: false

      def create
        session[:duz] = params[:duz].presence || "99996"
        session[:user_type] = params[:user_type].presence || "case_manager"
        session[:security_keys] = normalized_security_keys(params[:security_keys])
        # Tests exercising token-authenticated browser surfaces stash the
        # SMART token where the sign-on bridge does (#486): a browser token
        # is session-bound, so a header cannot present it.
        session[:smart_token] = params[:smart_token] if params[:smart_token].present?
        session[:user_name] = params[:user_name] if params[:user_name].present?
        head :ok
      end

      private

      # Arrays and comma-delimited strings normalize identically:
      # stripped, blank entries dropped.
      def normalized_security_keys(keys)
        list = keys.is_a?(Array) ? keys : keys.to_s.split(",")
        list.map { |k| k.to_s.strip }.reject(&:empty?)
      end

      # Refuse to exist outside the test environment — belt to the route-guard suspenders.
      def ensure_test_environment!
        raise ActionController::RoutingError, "Not Found" unless Rails.env.test?
      end
    end
  end
end
