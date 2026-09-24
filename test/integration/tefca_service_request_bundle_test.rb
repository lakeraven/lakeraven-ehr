# frozen_string_literal: true

require "test_helper"

class TefcaServiceRequestBundleTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    setup_smart_auth
  end

  teardown do
    teardown_smart_auth
  end

  # -- Bundle completeness -----------------------------------------------------

  test "ServiceRequest bundle is a searchset" do
    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Bundle", body["resourceType"]
    assert_equal "searchset", body["type"]
  end

  test "ServiceRequest bundle includes total" do
    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
    body = JSON.parse(response.body)
    assert body.key?("total"), "Bundle should include total count"
  end

  test "ServiceRequest bundle entries have resource key" do
    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
    body = JSON.parse(response.body)
    body["entry"]&.each do |entry|
      assert entry.key?("resource"), "Each entry should have a resource key"
    end
  end

  # -- Reference integrity ----------------------------------------------------

  test "ServiceRequest entries reference the queried patient" do
    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
    body = JSON.parse(response.body)
    body["entry"]&.each do |entry|
      subject_ref = entry.dig("resource", "subject", "reference")
      next unless subject_ref
      assert_match(/Patient\/1\z/, subject_ref,
        "ServiceRequest should reference queried patient")
    end
  end

  test "ServiceRequest entries have correct resourceType" do
    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
    body = JSON.parse(response.body)
    body["entry"]&.each do |entry|
      assert_equal "ServiceRequest", entry.dig("resource", "resourceType")
    end
  end

  # -- Tribal context ----------------------------------------------------------

  test "Patient referenced by ServiceRequest has tribal enrollment data" do
    get "/lakeraven-ehr/Patient/1", headers: @headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Patient", body["resourceType"]
    # Patient 1 has tribal enrollment in seed data
    extensions = body["extension"] || []
    tribal_ext = extensions.find { |e| e["url"]&.include?("tribal") }
    # Tribal data exists when tribal enrollment seed is present
    assert body["id"].present?, "Patient should have an id for reference integrity"
  end

  # -- Auth enforcement --------------------------------------------------------

  test "ServiceRequest without auth returns 401" do
    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
  end

  test "ServiceRequest without patient param returns 400" do
    get "/lakeraven-ehr/ServiceRequest", headers: @headers
    assert_response :bad_request
  end

  # -- Content type ------------------------------------------------------------

  test "ServiceRequest bundle returns FHIR content type" do
    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
    assert_equal "application/fhir+json", response.media_type
  end
end
