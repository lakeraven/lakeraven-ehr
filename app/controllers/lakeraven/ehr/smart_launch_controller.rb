# frozen_string_literal: true

module Lakeraven
  module EHR
    # SMART EHR Launch controller
    # ONC 170.315(g)(10)(iii) - Application registration and EHR launch
    class SmartLaunchController < ActionController::API
      def show
        unless params[:launch].present? && params[:iss].present?
          render json: { error: "invalid_request", error_description: "launch and iss parameters are required" },
                 status: :bad_request
          return
        end

        if params[:client_id].present?
          app = Doorkeeper::Application.find_by(uid: params[:client_id])
          if app
            redirect_to build_authorize_url(app), allow_other_host: true
            return
          end
        end

        render json: {
          launch: params[:launch],
          authorization_endpoint: authorization_endpoint,
          token_endpoint: token_endpoint
        }, status: :ok
      end

      private

      def authorization_endpoint
        "#{root_url}oauth/authorize"
      end

      def token_endpoint
        "#{root_url}oauth/token"
      end

      def root_url
        request.base_url + "/"
      end

      def build_authorize_url(app)
        query = {
          response_type: "code",
          client_id: app.uid,
          redirect_uri: app.redirect_uri,
          scope: "launch patient/*.read",
          state: SecureRandom.hex(16),
          launch: params[:launch],
          aud: params[:iss]
        }
        "#{authorization_endpoint}?#{query.to_query}"
      end
    end
  end
end
