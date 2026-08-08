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
        keys = params[:security_keys]
        session[:security_keys] = if keys.is_a?(Array)
          keys
        elsif keys.present?
          keys.to_s.split(",").map(&:strip)
        else
          []
        end
        head :ok
      end

      private

      # Refuse to exist outside the test environment — belt to the route-guard suspenders.
      def ensure_test_environment!
        raise ActionController::RoutingError, "Not Found" unless Rails.env.test?
      end
    end
  end
end
