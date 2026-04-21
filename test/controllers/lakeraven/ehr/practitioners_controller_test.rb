# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::PractitionersControllerTest < ActionDispatch::IntegrationTest
  test "GET /Practitioner/:ien returns 200 with FHIR Practitioner" do
    get "/lakeraven-ehr/Practitioner/101"
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "Practitioner", body["resourceType"]
    assert_equal "101", body["id"]
    assert_equal "MARTINEZ", body["name"].first["family"]
  end

  test "response includes NPI identifier" do
    get "/lakeraven-ehr/Practitioner/101"
    body = JSON.parse(response.body)
    npi_id = body["identifier"].find { |id| id["system"]&.include?("npi") }
    assert_equal "1234567890", npi_id["value"]
  end

  test "unknown IEN returns 404 OperationOutcome" do
    get "/lakeraven-ehr/Practitioner/99999"
    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "not-found", body["issue"].first["code"]
  end

  test "GET /Practitioner searches by name" do
    get "/lakeraven-ehr/Practitioner", params: { name: "MARTINEZ" }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Bundle", body["resourceType"]
    assert_equal 1, body["total"]
  end

  test "GET /Practitioner with no matches returns empty Bundle" do
    get "/lakeraven-ehr/Practitioner", params: { name: "ZZZZNONEXISTENT" }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal 0, body["total"]
  end
end
