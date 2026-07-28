# frozen_string_literal: true

module Lakeraven
  module EHR
    class SessionsController < WebController
      def new
        # login form
      end

      def create
        username = params[:username].to_s
        password = params[:password].to_s

        if username == "testprovider" && password == "test"
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
    end
  end
end
