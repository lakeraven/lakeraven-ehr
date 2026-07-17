# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Tests for the engine's test authorization server: client_credentials
    # issuance, SMART launch context resolution, refresh-token rotation,
    # and RFC 7662 introspection. All fixtures are synthetic (cartoon-
    # character patients only); token payloads must never carry PHI.
    class BackendServicesControllerTest < ActionDispatch::IntegrationTest
      setup do
        AuditEvent.delete_all
        LaunchContext.delete_all
        @oauth_app = Doorkeeper::Application.create!(
          name: "backend-services-test",
          redirect_uri: "https://example.test/callback",
          scopes: "system/*.read patient/Patient.read patient/Observation.read launch/patient offline_access",
          confidential: true
        )
      end

      teardown do
        AuditEvent.delete_all
        LaunchContext.delete_all
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      def client_assertion(app = @oauth_app)
        header = Base64.urlsafe_encode64({ alg: "RS384", typ: "JWT" }.to_json, padding: false)
        payload = Base64.urlsafe_encode64({ iss: app.uid, sub: app.uid }.to_json, padding: false)
        "#{header}.#{payload}.c2ln"
      end

      def mint_token(scopes: "system/*.read", launch: nil)
        params = {
          grant_type: "client_credentials",
          client_assertion: client_assertion,
          scope: scopes
        }
        params[:launch] = launch.launch_token if launch
        post "/lakeraven-ehr/oauth/token", params: params
        JSON.parse(response.body)
      end

      # -- client_credentials -------------------------------------------------

      test "client_credentials issues an access token and refresh token" do
        body = mint_token

        assert_response :ok
        assert body["access_token"].present?
        assert_equal "bearer", body["token_type"]
        assert_equal 3600, body["expires_in"]
        assert_equal "system/*.read", body["scope"]
        assert body["refresh_token"].present?
      end

      test "unsupported grant_type returns 400" do
        post "/lakeraven-ehr/oauth/token", params: { grant_type: "password" }
        assert_response :bad_request
        assert_equal "unsupported_grant_type", JSON.parse(response.body)["error"]
      end

      test "missing client_assertion returns 400" do
        post "/lakeraven-ehr/oauth/token", params: { grant_type: "client_credentials" }
        assert_response :bad_request
        assert_equal "invalid_client", JSON.parse(response.body)["error"]
      end

      test "unknown client returns 401" do
        header = Base64.urlsafe_encode64({ alg: "RS384" }.to_json, padding: false)
        payload = Base64.urlsafe_encode64({ iss: "unknown-client" }.to_json, padding: false)
        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "client_credentials", client_assertion: "#{header}.#{payload}.c2ln"
        }
        assert_response :unauthorized
      end

      test "issued token grants access to FHIR resources within its scope" do
        body = mint_token(scopes: "system/Patient.read")
        get "/lakeraven-ehr/Patient/1", headers: { "Authorization" => "Bearer #{body['access_token']}" }
        assert_response :ok
      end

      # -- launch context -----------------------------------------------------

      test "token request with launch binds patient and returns SMART context" do
        launch = LaunchContext.mint(
          oauth_application_uid: @oauth_app.uid,
          patient_dfn: "2",
          encounter_id: "enc-synthetic-1"
        )

        body = mint_token(scopes: "patient/Patient.read", launch: launch)

        assert_response :ok
        assert_equal "2", body["patient"]
        assert_equal "enc-synthetic-1", body["encounter"]
      end

      test "launch-bound token can only access the bound patient's resources" do
        launch = LaunchContext.mint(oauth_application_uid: @oauth_app.uid, patient_dfn: "2")
        body = mint_token(scopes: "patient/Patient.read", launch: launch)
        headers = { "Authorization" => "Bearer #{body['access_token']}" }

        get "/lakeraven-ehr/Patient/2", headers: headers
        assert_response :ok

        get "/lakeraven-ehr/Patient/1", headers: headers
        assert_response :forbidden
      end

      test "launch token minted for a different client is rejected" do
        other_app = Doorkeeper::Application.create!(
          name: "other", redirect_uri: "https://example.test/other",
          scopes: "patient/Patient.read", confidential: true
        )
        launch = LaunchContext.mint(oauth_application_uid: other_app.uid, patient_dfn: "2")

        body = mint_token(scopes: "patient/Patient.read", launch: launch)

        assert_response :bad_request
        assert_equal "invalid_grant", body["error"]
      end

      test "unknown launch token is rejected" do
        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "client_credentials",
          client_assertion: client_assertion,
          scope: "patient/Patient.read",
          launch: "lc_does_not_exist"
        }

        assert_response :bad_request
        assert_equal "invalid_grant", JSON.parse(response.body)["error"]
      end

      test "expired launch token is rejected" do
        launch = LaunchContext.mint(
          oauth_application_uid: @oauth_app.uid, patient_dfn: "2", ttl: 1.minute
        )
        travel 2.minutes

        body = mint_token(scopes: "patient/Patient.read", launch: launch)

        assert_response :bad_request
        assert_equal "invalid_grant", body["error"]
      ensure
        travel_back
      end

      # -- refresh token grant ------------------------------------------------

      test "refresh_token grant rotates and preserves patient context" do
        launch = LaunchContext.mint(oauth_application_uid: @oauth_app.uid, patient_dfn: "2")
        issued = mint_token(scopes: "patient/Patient.read", launch: launch)

        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "refresh_token",
          client_assertion: client_assertion,
          refresh_token: issued["refresh_token"]
        }

        assert_response :ok
        refreshed = JSON.parse(response.body)
        assert refreshed["access_token"].present?
        refute_equal issued["access_token"], refreshed["access_token"]
        assert refreshed["refresh_token"].present?
        assert_equal "2", refreshed["patient"]
        assert_equal "patient/Patient.read", refreshed["scope"]

        headers = { "Authorization" => "Bearer #{refreshed['access_token']}" }
        get "/lakeraven-ehr/Patient/2", headers: headers
        assert_response :ok
        get "/lakeraven-ehr/Patient/1", headers: headers
        assert_response :forbidden
      end

      test "reusing a rotated refresh token is rejected" do
        issued = mint_token

        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "refresh_token",
          client_assertion: client_assertion,
          refresh_token: issued["refresh_token"]
        }
        assert_response :ok

        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "refresh_token",
          client_assertion: client_assertion,
          refresh_token: issued["refresh_token"]
        }
        assert_response :bad_request
        assert_equal "invalid_grant", JSON.parse(response.body)["error"]
      end

      test "refresh token from a different client is rejected" do
        other_app = Doorkeeper::Application.create!(
          name: "other", redirect_uri: "https://example.test/other",
          scopes: "system/*.read", confidential: true
        )
        issued = mint_token

        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "refresh_token",
          client_assertion: client_assertion(other_app),
          refresh_token: issued["refresh_token"]
        }

        assert_response :bad_request
        assert_equal "invalid_grant", JSON.parse(response.body)["error"]
      end

      test "unknown refresh token is rejected" do
        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "refresh_token",
          client_assertion: client_assertion,
          refresh_token: "rt_does_not_exist"
        }

        assert_response :bad_request
        assert_equal "invalid_grant", JSON.parse(response.body)["error"]
      end

      test "missing refresh_token param returns 400" do
        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "refresh_token", client_assertion: client_assertion
        }
        assert_response :bad_request
        assert_equal "invalid_request", JSON.parse(response.body)["error"]
      end

      # -- introspection ------------------------------------------------------

      test "introspection returns active token metadata with launch context" do
        launch = LaunchContext.mint(oauth_application_uid: @oauth_app.uid, patient_dfn: "2")
        issued = mint_token(scopes: "patient/Patient.read", launch: launch)

        post "/lakeraven-ehr/oauth/introspect", params: {
          token: issued["access_token"], client_id: @oauth_app.uid
        }

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal true, body["active"]
        assert_equal "patient/Patient.read", body["scope"]
        assert_equal @oauth_app.uid, body["client_id"]
        assert body["exp"].present?
        assert_equal "2", body["patient"]
      end

      test "introspection reports unknown token as inactive" do
        post "/lakeraven-ehr/oauth/introspect", params: {
          token: "not-a-token", client_id: @oauth_app.uid
        }

        assert_response :ok
        assert_equal false, JSON.parse(response.body)["active"]
      end

      test "introspection reports revoked token as inactive" do
        issued = mint_token
        Doorkeeper::AccessToken.by_token(issued["access_token"]).revoke

        post "/lakeraven-ehr/oauth/introspect", params: {
          token: issued["access_token"], client_id: @oauth_app.uid
        }

        assert_equal false, JSON.parse(response.body)["active"]
      end

      test "introspection requires a token param" do
        post "/lakeraven-ehr/oauth/introspect", params: { client_id: @oauth_app.uid }
        assert_response :bad_request
      end

      test "introspection rejects unknown callers" do
        post "/lakeraven-ehr/oauth/introspect", params: { token: "x", client_id: "unknown" }
        assert_response :unauthorized
      end

      # -- PHI safety ---------------------------------------------------------

      test "token and introspection payloads contain no PHI" do
        launch = LaunchContext.mint(
          oauth_application_uid: @oauth_app.uid, patient_dfn: "2", encounter_id: "enc-synthetic-1"
        )
        post "/lakeraven-ehr/oauth/token", params: {
          grant_type: "client_credentials",
          client_assertion: client_assertion,
          scope: "patient/Patient.read",
          launch: launch.launch_token
        }
        token_payload = response.body
        access_token = JSON.parse(token_payload)["access_token"]

        post "/lakeraven-ehr/oauth/introspect", params: {
          token: access_token, client_id: @oauth_app.uid
        }
        introspected = response.body

        # Synthetic fixture PHI that must never appear in token payloads:
        # Mickey Mouse (DFN 2), SSN 000009999, DOB 2010-02-14.
        [ token_payload, introspected ].each do |payload|
          refute_includes payload, "MOUSE"
          refute_includes payload, "000009999"
          refute_includes payload, "2010-02-14"
          refute_includes payload, "birthDate"
          refute_includes payload, "ssn"
        end
      end

      # -- audit logging ------------------------------------------------------

      test "token issuance writes a hashed security AuditEvent" do
        assert_difference -> { AuditEvent.count }, 1 do
          mint_token
        end

        event = AuditEvent.recent.first
        assert_equal "security", event.event_type
        assert_equal "C", event.action
        assert_equal "0", event.outcome
        assert_equal "OAuthClient", event.entity_type
        assert_equal VistaRpc::PhiSanitizer.hash_identifier(@oauth_app.uid), event.entity_identifier
        refute_equal @oauth_app.uid, event.entity_identifier
      end

      test "token refresh writes a security AuditEvent" do
        issued = mint_token

        assert_difference -> { AuditEvent.count }, 1 do
          post "/lakeraven-ehr/oauth/token", params: {
            grant_type: "refresh_token",
            client_assertion: client_assertion,
            refresh_token: issued["refresh_token"]
          }
        end

        event = AuditEvent.recent.first
        assert_equal "security", event.event_type
        assert_equal "U", event.action
      end
    end
  end
end
