# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::PractitionersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @oauth_app = Doorkeeper::Application.create!(
      name: "test", redirect_uri: "https://example.test/callback",
      scopes: "system/Practitioner.read", confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @oauth_app, scopes: "system/Practitioner.read", expires_in: 3600
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  teardown do
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::Application.delete_all
  end

  test "GET /Practitioner/:ien returns 200 with FHIR Practitioner" do
    get "/lakeraven-ehr/Practitioner/101", headers: @headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Practitioner", body["resourceType"]
    assert_equal "101", body["id"]
    assert_equal "MARTINEZ", body["name"].first["family"]
  end

  test "response includes NPI identifier" do
    get "/lakeraven-ehr/Practitioner/101", headers: @headers
    body = JSON.parse(response.body)
    npi_id = body["identifier"].find { |id| id["system"]&.include?("npi") }
    assert_equal "1234567890", npi_id["value"]
  end

  test "unknown IEN returns 404 OperationOutcome" do
    get "/lakeraven-ehr/Practitioner/99999", headers: @headers
    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
  end

  test "GET /Practitioner searches by name" do
    get "/lakeraven-ehr/Practitioner", params: { name: "MARTINEZ" }, headers: @headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Bundle", body["resourceType"]
    assert_equal 1, body["total"]
  end

  test "GET /Practitioner with no matches returns empty Bundle" do
    get "/lakeraven-ehr/Practitioner", params: { name: "ZZZZNONEXISTENT" }, headers: @headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal 0, body["total"]
  end
end
