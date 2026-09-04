# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class PatientsControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper
      include BrokerStubbing

      setup do
        setup_internal_smart_auth
      end

      teardown do
        teardown_smart_auth
      end

      test "GET /Patient/:dfn returns 200 with FHIR Patient" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        assert_response :ok
        assert_equal "application/fhir+json", response.media_type
        body = JSON.parse(response.body)
        assert_equal "Patient", body["resourceType"]
        assert_equal "1", body["id"]
      end

      test "response includes US Core profile" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_includes body.dig("meta", "profile"),
                        "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
      end

      test "response includes name family and given" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "Anderson", body["name"].first["family"]
        assert_includes body["name"].first["given"], "Alice"
      end

      test "response includes gender and birthDate" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "female", body["gender"]
        assert_equal "1980-05-15", body["birthDate"]
      end

      test "response includes SSN identifier" do
        get "/lakeraven-ehr/Patient/1", headers: @headers
        body = JSON.parse(response.body)
        ssn_id = body["identifier"].find { |id| id["system"]&.include?("ssn") }
        assert_equal "111-11-1111", ssn_id["value"]
      end

      test "unknown DFN returns 404 OperationOutcome" do
        get "/lakeraven-ehr/Patient/99999", headers: @headers
        assert_response :not_found
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
      end

      test "GET /Patient searches by name" do
        get "/lakeraven-ehr/Patient", params: { name: "Anderson" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_operator body["total"], :>=, 1
      end

      test "GET /Patient with no matches returns empty Bundle" do
        get "/lakeraven-ehr/Patient", params: { name: "ZZZZNONEXISTENT" }, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal 0, body["total"]
      end

      test "requires auth" do
        get "/lakeraven-ehr/Patient/1"
        assert_response :unauthorized
      end

      # -- Expired/revoked/invalid token auth ------------------------------------

      test "expired token returns 401" do
        expired = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: -1
        )
        get "/lakeraven-ehr/Patient/1",
          headers: { "Authorization" => "Bearer #{expired.plaintext_token || expired.token}" }
        assert_response :unauthorized
      end

      test "revoked token returns 401" do
        revoked = Doorkeeper::AccessToken.create!(
          application: @oauth_app, scopes: "system/*.read", expires_in: 3600
        )
        revoked.revoke
        get "/lakeraven-ehr/Patient/1",
          headers: { "Authorization" => "Bearer #{revoked.plaintext_token || revoked.token}" }
        assert_response :unauthorized
      end

      test "invalid token returns 401" do
        get "/lakeraven-ehr/Patient/1",
          headers: { "Authorization" => "Bearer totally_bogus_token" }
        assert_response :unauthorized
      end

      # -- Scope enforcement -----------------------------------------------------

      test "token without Patient read scope returns 403" do
        app = Doorkeeper::Application.create!(
          name: "scope-test", redirect_uri: "https://example.test/callback",
          scopes: "openid", confidential: true
        )
        token = Doorkeeper::AccessToken.create!(application: app, scopes: "openid", expires_in: 3600)
        get "/lakeraven-ehr/Patient/1",
          headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
        assert_response :forbidden
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "forbidden", body["issue"].first["code"]
      end

      # -- Error response structure ----------------------------------------------

      test "401 response is OperationOutcome" do
        get "/lakeraven-ehr/Patient/1"
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "login", body["issue"].first["code"]
      end

      test "404 response is OperationOutcome with not-found code" do
        get "/lakeraven-ehr/Patient/99999", headers: @headers
        body = JSON.parse(response.body)
        assert_equal "OperationOutcome", body["resourceType"]
        assert_equal "not-found", body["issue"].first["code"]
        assert_equal "error", body["issue"].first["severity"]
      end

      test "FHIR content type on 401 responses" do
        get "/lakeraven-ehr/Patient/1"
        assert_equal "application/fhir+json", response.media_type
      end

      test "FHIR content type on 404 responses" do
        get "/lakeraven-ehr/Patient/99999", headers: @headers
        assert_equal "application/fhir+json", response.media_type
      end

      # -- POST /Patient (register) ----------------------------------------------

      def patient_fhir
        {
          resourceType: "Patient",
          name: [ { family: "TESTPATIENT", given: [ "SYNTH" ] } ],
          gender: "female",
          birthDate: "1985-06-15",
          identifier: [ { system: "http://hl7.org/fhir/sid/us-ssn", value: "111-11-1111" } ]
        }
      end

      def fhir_headers
        @headers.merge("Content-Type" => "application/fhir+json")
      end

      test "POST Patient registers and returns 201 with Location" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^12345^")
        use_broker(fake) do
          post "/lakeraven-ehr/Patient", params: patient_fhir.to_json, headers: fhir_headers
        end
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Patient", body["resourceType"]
        assert_equal "12345", body["id"]
        assert_match %r{/Patient/12345\z}, response.headers["Location"]
        assert_equal RegistrationGateway::REGISTER_RPC, fake.last_call[:rpc]
      end

      test "POST Patient without write scope is forbidden" do
        setup_internal_smart_auth(scopes: "user/Patient.read")
        post "/lakeraven-ehr/Patient", params: patient_fhir.to_json, headers: fhir_headers
        assert_response :forbidden
      end

      test "POST Patient without a token is unauthorized" do
        post "/lakeraven-ehr/Patient", params: patient_fhir.to_json,
          headers: { "Content-Type" => "application/fhir+json" }
        assert_response :unauthorized
      end

      test "POST Patient missing name is unprocessable" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        use_broker(FakeBroker.new) do
          post "/lakeraven-ehr/Patient",
            params: { resourceType: "Patient", gender: "female" }.to_json, headers: fhir_headers
        end
        assert_response :unprocessable_content
      end

      test "POST Patient maps FHIR fields into the registration payload" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^12345^")
        use_broker(fake) do
          post "/lakeraven-ehr/Patient", params: patient_fhir.to_json, headers: fhir_headers
        end
        assert_response :created
        payload = fake.last_call[:params].join(" ")
        assert_includes payload, "TESTPATIENT,SYNTH"
        assert_includes payload, "111-11-1111"
        assert_match(/\^F\^/, payload)
      end

      test "POST Patient surfaces a broker outage as 503" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        fake = FakeBroker.new.raise_with(RpmsRpc::Client::ConnectionError.new("broker down"))
        use_broker(fake) do
          post "/lakeraven-ehr/Patient", params: patient_fhir.to_json, headers: fhir_headers
        end
        assert_response :service_unavailable
      end

      test "POST Patient rejects invalid JSON with a distinct 400" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        post "/lakeraven-ehr/Patient", params: "not json", headers: fhir_headers
        assert_response :bad_request
        assert_includes response.body, "not valid JSON"
      end

      test "POST Patient rejects a non-Patient resource" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        post "/lakeraven-ehr/Patient", params: { resourceType: "Observation" }.to_json, headers: fhir_headers
        assert_response :bad_request
      end

      test "POST Patient returns 502 when the gateway reports success but no DFN" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^^")
        use_broker(fake) do
          post "/lakeraven-ehr/Patient", params: patient_fhir.to_json, headers: fhir_headers
        end
        assert_response :bad_gateway
      end

      test "POST Patient reads the SSN identifier even when it is not first" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        body = patient_fhir.merge(identifier: [
          { system: "http://hospital.example/mrn", value: "MRN-999" },
          { system: "http://hl7.org/fhir/sid/us-ssn", value: "222-22-2222" }
        ])
        fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^12345^")
        use_broker(fake) do
          post "/lakeraven-ehr/Patient", params: body.to_json, headers: fhir_headers
        end
        assert_includes fake.last_call[:params].join(" "), "222-22-2222"
        refute_includes fake.last_call[:params].join(" "), "MRN-999"
      end

      test "POST Patient does not echo an unsupported gender as accepted" do
        setup_internal_smart_auth(scopes: "user/Patient.write")
        body = patient_fhir.merge(gender: "other")
        fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^12345^")
        use_broker(fake) do
          post "/lakeraven-ehr/Patient", params: body.to_json, headers: fhir_headers
        end
        assert_response :created
        refute JSON.parse(response.body).key?("gender")
      end

      test "POST Patient forbids a patient-context token from registering" do
        setup_smart_auth(scopes: "patient/Patient.write")
        post "/lakeraven-ehr/Patient", params: patient_fhir.to_json, headers: fhir_headers
        assert_response :forbidden
      end

      test "POST Patient accepts the SMART v2 create (.c) scope" do
        setup_internal_smart_auth(scopes: "user/Patient.c")
        fake = FakeBroker.new.on(RegistrationGateway::REGISTER_RPC, "1^12345^")
        use_broker(fake) do
          post "/lakeraven-ehr/Patient", params: patient_fhir.to_json, headers: fhir_headers
        end
        assert_response :created
      end
    end
  end
end
