# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class SmartConfigurationControllerTest < ActionDispatch::IntegrationTest
      test "returns SMART configuration JSON" do
        get "/lakeraven-ehr/.well-known/smart-configuration"

        assert_response :ok
        config = JSON.parse(response.body)

        assert config["authorization_endpoint"].present?
        assert config["token_endpoint"].present?
      end

      test "includes SMART capabilities" do
        get "/lakeraven-ehr/.well-known/smart-configuration"

        config = JSON.parse(response.body)

        assert_includes config["capabilities"], "launch-ehr"
        assert_includes config["capabilities"], "launch-standalone"
        assert_includes config["capabilities"], "sso-openid-connect"
      end

      test "includes supported scopes" do
        get "/lakeraven-ehr/.well-known/smart-configuration"

        config = JSON.parse(response.body)

        assert_includes config["scopes_supported"], "openid"
        assert_includes config["scopes_supported"], "patient/Patient.read"
        assert_includes config["scopes_supported"], "user/Patient.read"
        assert_includes config["scopes_supported"], "system/*.read"
      end

      test "includes PKCE support" do
        get "/lakeraven-ehr/.well-known/smart-configuration"

        config = JSON.parse(response.body)

        assert_includes config["code_challenge_methods_supported"], "S256"
      end

      test "includes grant types" do
        get "/lakeraven-ehr/.well-known/smart-configuration"

        config = JSON.parse(response.body)

        assert_includes config["grant_types_supported"], "authorization_code"
        assert_includes config["grant_types_supported"], "client_credentials"
        assert_includes config["grant_types_supported"], "refresh_token"
      end

      test "includes OIDC endpoints" do
        get "/lakeraven-ehr/.well-known/smart-configuration"

        config = JSON.parse(response.body)

        assert config["userinfo_endpoint"].present?
        assert config["jwks_uri"].present?
      end

      test "does not require authentication" do
        get "/lakeraven-ehr/.well-known/smart-configuration"

        assert_response :ok
      end

      test "returns JSON content type" do
        get "/lakeraven-ehr/.well-known/smart-configuration"

        assert_equal "application/json", response.media_type
      end
    end
  end
end
