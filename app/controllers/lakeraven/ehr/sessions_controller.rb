# frozen_string_literal: true

module Lakeraven
  module EHR
    class SessionsController < WebController
      # The canned-credential branch must never be reachable outside test, even
      # if the route gate is loosened by mistake (#401 interim; real sign-on: #332).
      before_action :ensure_test_environment!, only: :create

      def new
        # login form
      end

      def create
        username = params[:username].to_s
        password = params[:password].to_s

        if username == "testprovider" && password == "test"
          reset_session
          session[:duz] = "99999"
          session[:user_type] = "provider"
          session[:user_name] = "Test Provider"
          redirect_to dashboard_path
        else
          flash.now[:alert] = "Invalid username or password"
          render :new, status: :unprocessable_entity
        end
      end

      def destroy
        reset_session
        redirect_to login_path, notice: "Signed out"
      end

      private

      def ensure_test_environment!
        raise ActionController::RoutingError, "Not Found" unless Rails.env.test?
      end
    end
  end
end
