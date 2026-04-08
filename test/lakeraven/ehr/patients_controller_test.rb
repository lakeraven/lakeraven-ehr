# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::PatientsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
    Lakeraven::EHR::AuditEvent.delete_all
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::AccessGrant.delete_all
    Doorkeeper::Application.delete_all

    @adapter = Lakeraven::EHR::Adapters::MockAdapter.new
    Lakeraven::EHR.configure { |c| c.adapter = @adapter }

    @patient_identifier = @adapter.seed_patient(
      tenant_identifier: "tnt_test",
      facility_identifier: "fac_main",
      display_name: "DOE,JOHN",
      date_of_birth: Date.new(1980, 1, 15),
      gender: "male"
    )
    @adapter.attach_patient_identifier(
      tenant_identifier: "tnt_test",
      patient_identifier: @patient_identifier,
      system: "http://hl7.org/fhir/sid/us-ssn",
      value: "111-11-1111"
    )

    @oauth_app = Doorkeeper::Application.create!(
      name: "test client",
      redirect_uri: "https://example.test/callback",
      scopes: "system/Patient.read patient/Patient.read",
      confidential: true
    )
  end

  teardown do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
  end

  def issue_token(scopes: "system/Patient.read", patient: nil)
    Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: patient,
      scopes: scopes,
      expires_in: 3600
    )
  end

  def auth_headers(token: nil, tenant: "tnt_test", facility: "fac_main", scopes: "system/Patient.read", patient: nil)
    token ||= issue_token(scopes: scopes, patient: patient)
    plaintext = token.plaintext_token || token.token
    headers = { "Authorization" => "Bearer #{plaintext}" }
    headers["X-Tenant-Identifier"] = tenant if tenant
    headers["X-Facility-Identifier"] = facility if facility
    headers
  end

  test "GET /Patient/:identifier returns 200 with the FHIR Patient resource" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: auth_headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "Patient", body["resourceType"]
    assert_equal @patient_identifier, body["id"]
  end

  test "response includes US Core profile in meta.profile" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: auth_headers
    body = JSON.parse(response.body)
    assert_includes body.dig("meta", "profile"), "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
  end

  test "response includes name family + given parsed from display_name" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: auth_headers
    body = JSON.parse(response.body)
    assert_equal "DOE", body["name"].first["family"]
    assert_includes body["name"].first["given"], "JOHN"
  end

  test "response includes the SSN identifier round-tripped" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: auth_headers
    body = JSON.parse(response.body)
    assert_includes body["identifier"], { "system" => "http://hl7.org/fhir/sid/us-ssn", "value" => "111-11-1111" }
  end

  test "unknown patient identifier returns 404 OperationOutcome" do
    get "/lakeraven-ehr/Patient/pt_does_not_exist", headers: auth_headers
    assert_response :not_found
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    issue = body["issue"].first
    assert_equal "error", issue["severity"]
    assert_equal "not-found", issue["code"]
  end

  test "cross-tenant identifier returns 404 (not 403) so the tenant boundary doesn't leak existence" do
    other_identifier = @adapter.seed_patient(
      tenant_identifier: "tnt_other", facility_identifier: "fac_main",
      display_name: "OTHER,PERSON", date_of_birth: Date.new(1990, 1, 1), gender: "male"
    )
    get "/lakeraven-ehr/Patient/#{other_identifier}", headers: auth_headers
    assert_response :not_found
  end

  test "missing tenant header returns 400 OperationOutcome with code required" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}"
    assert_response :bad_request
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    issue = body["issue"].first
    assert_equal "error", issue["severity"]
    assert_equal "required", issue["code"]
  end

  test "whitespace-only tenant header is treated the same as missing" do
    # Regression for Copilot review on PR #3: a header of " " was
    # slipping past the blank check and producing a 404 downstream
    # instead of the intended 400 required OperationOutcome.
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: { "X-Tenant-Identifier" => "   " }
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "required", body["issue"].first["code"]
  end

  test "Current is reset after the request so state doesn't leak across actions" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: auth_headers
    assert_response :ok
    # ActiveSupport::CurrentAttributes auto-resets after the request
    # via the railtie integration. We just verify it didn't carry over.
    assert_nil Lakeraven::EHR::Current.tenant_identifier
  end

  # -- SMART auth boundary ---------------------------------------------------

  test "request without Bearer token returns 401 OperationOutcome login" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}",
        headers: { "X-Tenant-Identifier" => "tnt_test" }
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "login", body["issue"].first["code"]
  end

  test "request with token missing read scope returns 403 forbidden" do
    headers = auth_headers(scopes: "openid")
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: headers
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "forbidden", body["issue"].first["code"]
  end

  test "system/Patient.read scope grants access" do
    headers = auth_headers(scopes: "system/Patient.read")
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: headers
    assert_response :ok
  end

  test "user/Patient.read scope grants access" do
    headers = auth_headers(scopes: "user/Patient.read")
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: headers
    assert_response :ok
  end

  test "patient/Patient.read with matching bound patient grants access" do
    headers = auth_headers(scopes: "patient/Patient.read", patient: @patient_identifier)
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: headers
    assert_response :ok
  end

  test "patient/Patient.read with mismatched bound patient returns 403 forbidden" do
    headers = auth_headers(scopes: "patient/Patient.read", patient: "pt_other")
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: headers
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "forbidden", body["issue"].first["code"]
  end

  test "patient/Patient.read with no bound patient returns 403 forbidden" do
    headers = auth_headers(scopes: "patient/Patient.read", patient: nil)
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: headers
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "forbidden", body["issue"].first["code"]
  end

  # -- audit logging --------------------------------------------------------

  test "a successful GET produces an AuditEvent row" do
    assert_difference -> { Lakeraven::EHR::AuditEvent.count }, 1 do
      get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: auth_headers
    end
    event = Lakeraven::EHR::AuditEvent.recent.first
    assert_equal "rest", event.event_type
    assert_equal "R", event.action
    assert_equal "0", event.outcome
    assert_equal "tnt_test", event.tenant_identifier
    assert_equal "fac_main", event.facility_identifier
    assert_equal "Patient", event.entity_type
    assert_equal @patient_identifier, event.entity_identifier
    assert_equal "Application", event.agent_who_type
    assert_equal @oauth_app.uid, event.agent_who_identifier
  end

  test "a 404 response produces an AuditEvent with minor-failure outcome" do
    assert_difference -> { Lakeraven::EHR::AuditEvent.count }, 1 do
      get "/lakeraven-ehr/Patient/pt_does_not_exist", headers: auth_headers
    end
    event = Lakeraven::EHR::AuditEvent.recent.first
    assert_equal "4", event.outcome
    assert_equal "pt_does_not_exist", event.entity_identifier
  end

  test "a 401 auth failure does NOT produce an AuditEvent" do
    # The audit concern runs as after_action inside the PatientsController
    # request cycle. A 401 from authenticate_smart_token! short-circuits
    # before reaching the show action and before the after_action fires.
    # That's intentional: failed auth is logged at the auth layer, not
    # as a successful PHI access.
    assert_no_difference -> { Lakeraven::EHR::AuditEvent.count } do
      get "/lakeraven-ehr/Patient/#{@patient_identifier}",
          headers: { "X-Tenant-Identifier" => "tnt_test" }
    end
  end

  test "audit rows are immutable" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: auth_headers
    event = Lakeraven::EHR::AuditEvent.recent.first
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(outcome: "4") }
  end

  test "custom tenant_resolver overrides the default header reader" do
    # Integration lock-in: a host application override (subdomain,
    # JWT claim, anything) replaces the default header read and
    # flows through ApplicationController + Current + the adapter
    # call without any code changes to the engine.
    Lakeraven::EHR.configure do |config|
      config.tenant_resolver = ->(_request) { "tnt_test" }
      config.facility_resolver = ->(_request) { "fac_main" }
    end
    # NO X-Tenant-Identifier header — the resolver hard-codes it.
    token = issue_token(scopes: "system/Patient.read")
    plaintext = token.plaintext_token || token.token
    get "/lakeraven-ehr/Patient/#{@patient_identifier}",
        headers: { "Authorization" => "Bearer #{plaintext}" }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Patient", body["resourceType"]
  end
end
