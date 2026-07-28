# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # SMART scope enforcement for patient-compartment searches, RFC 6750
    # challenge headers, and VistA-backend coverage. A patient-scoped
    # token may only read its bound patient's compartment; system and
    # user scopes bypass the compartment check.
    class SmartScopeEnforcementTest < ActionDispatch::IntegrationTest
      COMPARTMENT_SEARCHES = {
        "Observation" => "patient/Observation.read",
        "Condition" => "patient/Condition.read",
        "AllergyIntolerance" => "patient/AllergyIntolerance.read",
        "MedicationRequest" => "patient/MedicationRequest.read",
        "Immunization" => "patient/Immunization.read",
        "Procedure" => "patient/Procedure.read",
        "Encounter" => "patient/Encounter.read",
        "ServiceRequest" => "patient/ServiceRequest.read"
      }.freeze

      setup do
        @oauth_app = Doorkeeper::Application.create!(
          name: "scope-enforcement-test",
          redirect_uri: "https://example.test/callback",
          scopes: COMPARTMENT_SEARCHES.values.uniq.join(" "),
          confidential: true
        )
      end

      teardown do
        Doorkeeper::AccessToken.delete_all
        Doorkeeper::Application.delete_all
      end

      def auth_headers(scopes:, patient: nil)
        token = Doorkeeper::AccessToken.create!(
          application: @oauth_app,
          resource_owner_id: patient,
          scopes: scopes,
          expires_in: 3600
        )
        { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
      end

      # -- RFC 6750 WWW-Authenticate challenges -------------------------------

      test "401 response carries invalid_token challenge" do
        get "/lakeraven-ehr/Patient/1", headers: { "Authorization" => "Bearer bogus" }

        assert_response :unauthorized
        challenge = response.headers["WWW-Authenticate"]
        assert challenge.present?
        assert_includes challenge, "Bearer"
        assert_includes challenge, "invalid_token"
      end

      test "403 response carries insufficient_scope challenge" do
        get "/lakeraven-ehr/Patient/1", headers: auth_headers(scopes: "openid")

        assert_response :forbidden
        challenge = response.headers["WWW-Authenticate"]
        assert challenge.present?
        assert_includes challenge, "insufficient_scope"
      end

      # -- Patient compartment on compartment searches ------------------------

      COMPARTMENT_SEARCHES.each do |resource, scope|
        test "patient-scoped token denied for other patient's #{resource} compartment" do
          get "/lakeraven-ehr/#{resource}", params: { patient: "1" },
              headers: auth_headers(scopes: scope, patient: "2")
          assert_response :forbidden
        end

        test "patient-scoped token denied for #{resource} without bound patient" do
          get "/lakeraven-ehr/#{resource}", params: { patient: "1" },
              headers: auth_headers(scopes: scope)
          assert_response :forbidden
        end

        test "patient-scoped token reads own #{resource} compartment" do
          get "/lakeraven-ehr/#{resource}", params: { patient: "1" },
              headers: auth_headers(scopes: scope, patient: "1")
          assert_response :ok
        end

        test "system scope bypasses #{resource} compartment check" do
          get "/lakeraven-ehr/#{resource}", params: { patient: "1" },
              headers: auth_headers(scopes: "system/#{resource}.read")
          assert_response :ok
        end
      end

      test "compartment check accepts Patient/ prefixed reference" do
        get "/lakeraven-ehr/Observation", params: { patient: "Patient/1" },
            headers: auth_headers(scopes: "patient/Observation.read", patient: "1")
        assert_response :ok
      end

      test "patient wildcard scope reads own compartment" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" },
            headers: auth_headers(scopes: "patient/*.read", patient: "1")
        assert_response :ok
      end

      # -- VistA backend: same enforcement applies ----------------------------

      test "VistA backend enforces scopes and patient compartment" do
        Lakeraven::EHR.configure { |c| c.backend = :vista }
        Lakeraven::EHR::Backend.reset!

        get "/lakeraven-ehr/Patient/1"
        assert_response :unauthorized

        get "/lakeraven-ehr/Patient/1", headers: auth_headers(scopes: "openid")
        assert_response :forbidden

        get "/lakeraven-ehr/Patient/1",
            headers: auth_headers(scopes: "patient/Patient.read", patient: "1")
        assert_response :ok

        get "/lakeraven-ehr/Patient/1",
            headers: auth_headers(scopes: "patient/Patient.read", patient: "2")
        assert_response :forbidden

        get "/lakeraven-ehr/Observation", params: { patient: "1" },
            headers: auth_headers(scopes: "patient/Observation.read", patient: "1")
        assert_response :ok

        get "/lakeraven-ehr/Observation", params: { patient: "2" },
            headers: auth_headers(scopes: "patient/Observation.read", patient: "1")
        assert_response :forbidden
      ensure
        Lakeraven::EHR.configure { |c| c.backend = :rpms }
        Lakeraven::EHR::Backend.reset!
      end

      test "VistA backend enforces compartment on Condition and AllergyIntolerance" do
        Lakeraven::EHR.configure { |c| c.backend = :vista }
        Lakeraven::EHR::Backend.reset!

        get "/lakeraven-ehr/Condition", params: { patient: "1" },
            headers: auth_headers(scopes: "patient/Condition.read", patient: "1")
        assert_response :ok

        get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "2" },
            headers: auth_headers(scopes: "patient/AllergyIntolerance.read", patient: "1")
        assert_response :forbidden
      ensure
        Lakeraven::EHR.configure { |c| c.backend = :rpms }
        Lakeraven::EHR::Backend.reset!
      end
    end
  end
end
