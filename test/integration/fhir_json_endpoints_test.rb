# frozen_string_literal: true

require "test_helper"

class FhirJsonEndpointsTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    setup_smart_auth
  end

  teardown do
    teardown_smart_auth
  end

  # -- Content type ------------------------------------------------------------

  test "Patient read returns application/fhir+json" do
    get "/lakeraven-ehr/Patient/1", headers: @headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
  end

  test "Patient search returns application/fhir+json" do
    get "/lakeraven-ehr/Patient", params: { name: "Anderson" }, headers: @headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
  end

  test "Encounter search returns application/fhir+json" do
    get "/lakeraven-ehr/Encounter", params: { patient: "1" }, headers: @headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
  end

  test "Observation search returns application/fhir+json" do
    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
  end

  test "Condition search returns application/fhir+json" do
    get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
  end

  test "AllergyIntolerance search returns application/fhir+json" do
    get "/lakeraven-ehr/AllergyIntolerance", params: { patient: "1" }, headers: @headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
  end

  test "MedicationRequest search returns application/fhir+json" do
    get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
  end

  # -- Bundle structure --------------------------------------------------------

  test "search endpoints return Bundle resourceType" do
    %w[Encounter Observation Condition AllergyIntolerance MedicationRequest].each do |resource|
      get "/lakeraven-ehr/#{resource}", params: { patient: "1" }, headers: @headers
      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal "Bundle", body["resourceType"], "#{resource} should return Bundle"
      assert_equal "searchset", body["type"], "#{resource} should be searchset"
      assert body.key?("total"), "#{resource} bundle should include total"
      assert body.key?("entry"), "#{resource} bundle should include entry"
    end
  end

  test "read endpoint returns single resource not Bundle" do
    get "/lakeraven-ehr/Patient/1", headers: @headers
    body = JSON.parse(response.body)
    assert_equal "Patient", body["resourceType"]
    assert_nil body["entry"], "Read should return resource, not bundle"
  end

  # -- 404 handling ------------------------------------------------------------

  test "Patient read 404 returns OperationOutcome" do
    get "/lakeraven-ehr/Patient/99999", headers: @headers
    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "not-found", body["issue"].first["code"]
    assert_equal "error", body["issue"].first["severity"]
  end

  test "Patient read 404 returns FHIR content type" do
    get "/lakeraven-ehr/Patient/99999", headers: @headers
    assert_equal "application/fhir+json", response.media_type
  end

  test "Practitioner read 404 returns OperationOutcome" do
    get "/lakeraven-ehr/Practitioner/99999", headers: @headers
    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
  end

  test "Condition show 404 returns OperationOutcome" do
    get "/lakeraven-ehr/Condition/99999", headers: @headers
    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "not-found", body["issue"].first["code"]
  end

  # -- Missing required params -------------------------------------------------

  test "search without patient param returns 400 OperationOutcome" do
    %w[Encounter Observation Condition AllergyIntolerance MedicationRequest].each do |resource|
      get "/lakeraven-ehr/#{resource}", headers: @headers
      assert_response :bad_request, "#{resource} should require patient param"
      body = JSON.parse(response.body)
      assert_equal "OperationOutcome", body["resourceType"], "#{resource} 400 should be OperationOutcome"
    end
  end

  # -- Auth enforcement --------------------------------------------------------

  test "all endpoints require auth" do
    endpoints = [
      [ "/lakeraven-ehr/Patient/1", {} ],
      [ "/lakeraven-ehr/Encounter", { patient: "1" } ],
      [ "/lakeraven-ehr/Observation", { patient: "1" } ],
      [ "/lakeraven-ehr/Condition", { patient: "1" } ]
    ]
    endpoints.each do |path, params_hash|
      get path, params: params_hash
      assert_response :unauthorized, "#{path} should require auth"
      body = JSON.parse(response.body)
      assert_equal "OperationOutcome", body["resourceType"]
    end
  end
end
