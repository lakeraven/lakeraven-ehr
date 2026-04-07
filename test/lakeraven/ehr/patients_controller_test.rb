# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::PatientsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
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
  end

  teardown do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
  end

  def tenant_headers(facility: "fac_main")
    headers = { "X-Tenant-Identifier" => "tnt_test" }
    headers["X-Facility-Identifier"] = facility if facility
    headers
  end

  test "GET /Patient/:identifier returns 200 with the FHIR Patient resource" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: tenant_headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "Patient", body["resourceType"]
    assert_equal @patient_identifier, body["id"]
  end

  test "response includes US Core profile in meta.profile" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: tenant_headers
    body = JSON.parse(response.body)
    assert_includes body.dig("meta", "profile"), "http://hl7.org/fhir/us/core/StructureDefinition/us-core-patient"
  end

  test "response includes name family + given parsed from display_name" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: tenant_headers
    body = JSON.parse(response.body)
    assert_equal "DOE", body["name"].first["family"]
    assert_includes body["name"].first["given"], "JOHN"
  end

  test "response includes the SSN identifier round-tripped" do
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: tenant_headers
    body = JSON.parse(response.body)
    assert_includes body["identifier"], { "system" => "http://hl7.org/fhir/sid/us-ssn", "value" => "111-11-1111" }
  end

  test "unknown patient identifier returns 404 OperationOutcome" do
    get "/lakeraven-ehr/Patient/pt_does_not_exist", headers: tenant_headers
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
    get "/lakeraven-ehr/Patient/#{other_identifier}", headers: tenant_headers
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
    get "/lakeraven-ehr/Patient/#{@patient_identifier}", headers: tenant_headers
    assert_response :ok
    # ActiveSupport::CurrentAttributes auto-resets after the request
    # via the railtie integration. We just verify it didn't carry over.
    assert_nil Lakeraven::EHR::Current.tenant_identifier
  end
end
