# frozen_string_literal: true

module Lakeraven
  module EHR
    # A client registered to use SMART App Launch (#839): a Doorkeeper
    # application, the same registry Backend Services clients live in, with a
    # real redirect URI. How it authenticates at the token endpoint follows
    # from its registration:
    #
    #   public        confidential: false. Proves nothing but PKCE.
    #   symmetric     confidential, no jwks_uri: a client secret (Basic or body).
    #   asymmetric    confidential, a jwks_uri: a JWT signed with a key from it.
    #
    # Not a launch client: the engine's own browser-session application, and a
    # Backend Services client registered with the out-of-band redirect URI.
    module LaunchClient
      OUT_OF_BAND = "urn:ietf:wg:oauth:2.0:oob"
      # SMART's confidential asymmetric profile: servers support both.
      ASSERTION_ALGORITHMS = %w[RS384 ES384].freeze

      module_function

      def find(client_id)
        return nil unless client_id.is_a?(String) && client_id.present?
        return nil if client_id == SessionsController::BROWSER_SSO_APP_UID

        app = Doorkeeper::Application.find_by(uid: client_id)
        launch_client?(app) ? app : nil
      end

      def launch_client?(app)
        return false if app.nil? || app.uid == SessionsController::BROWSER_SSO_APP_UID

        uris = app.redirect_uri.to_s.split
        uris.any? && uris.exclude?(OUT_OF_BAND)
      end

      def kind(app)
        return :public unless app.confidential?

        app.jwks_uri.present? ? :asymmetric : :symmetric
      end
    end
  end
end
