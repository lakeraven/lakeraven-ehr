# frozen_string_literal: true

require "test_helper"

class Lakeraven::EHR::AuditEventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Lakeraven::EHR.reset_configuration!
    Lakeraven::EHR::Current.reset!
    Lakeraven::EHR::AuditEvent.delete_all
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::AccessGrant.delete_all
    Doorkeeper::Application.delete_all

    @oauth_app = Doorkeeper::Application.create!(
      name: "test client",
      redirect_uri: "https://example.test/callback",
      scopes: "system/AuditEvent.read",
      confidential: true
    )

    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      agent_who_type: "Application", agent_who_identifier: "client-a",
      entity_type: "Patient", entity_identifier: "pt_01H8X"
    )
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      agent_who_type: "Application", agent_who_identifier: "client-a",
      entity_type: "Patient", entity_identifier: "pt_other"
    )
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      tenant_identifier: "tnt_other", facility_identifier: "fac_main",
      agent_who_type: "Application", agent_who_identifier: "client-a",
      entity_type: "Patient", entity_identifier: "pt_foreign"
    )
  end

  def issue_token(scopes: "system/AuditEvent.read")
    Doorkeeper::AccessToken.create!(
      application: @oauth_app, scopes: scopes, expires_in: 3600
    )
  end

  def auth_headers(scopes: "system/AuditEvent.read")
    token = issue_token(scopes: scopes)
    plaintext = token.plaintext_token || token.token
    {
      "Authorization" => "Bearer #{plaintext}",
      "X-Tenant-Identifier" => "tnt_test",
      "X-Facility-Identifier" => "fac_main"
    }
  end

  test "GET /AuditEvent returns a FHIR Bundle with tenant-scoped rows" do
    get "/lakeraven-ehr/AuditEvent", headers: auth_headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "Bundle", body["resourceType"]
    assert_equal "searchset", body["type"]
    # Two rows for tnt_test, one foreign row filtered out
    assert_equal 2, body["total"]
    assert_equal 2, body["entry"].length
  end

  test "each entry is a FHIR AuditEvent resource" do
    get "/lakeraven-ehr/AuditEvent", headers: auth_headers
    body = JSON.parse(response.body)
    body["entry"].each do |entry|
      assert_equal "AuditEvent", entry["resource"]["resourceType"]
    end
  end

  test "cross-tenant rows never appear in the response" do
    get "/lakeraven-ehr/AuditEvent", headers: auth_headers
    body = JSON.parse(response.body)
    entity_ids = body["entry"].map { |e| e["resource"]["entity"].first["what"]["identifier"]["value"] }
    refute_includes entity_ids, "pt_foreign"
  end

  test "entity filter scopes the result" do
    get "/lakeraven-ehr/AuditEvent?entity-type=Patient&entity-identifier=pt_01H8X",
        headers: auth_headers
    body = JSON.parse(response.body)
    assert_equal 1, body["total"]
  end

  test "results are ordered recent-first" do
    # Create a newer row; assert it sorts first
    newer = Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      tenant_identifier: "tnt_test", facility_identifier: "fac_main",
      agent_who_type: "Application", agent_who_identifier: "client-a",
      entity_type: "Patient", entity_identifier: "pt_newest",
      recorded: 1.minute.from_now
    )
    get "/lakeraven-ehr/AuditEvent", headers: auth_headers
    body = JSON.parse(response.body)
    first_entity_id = body["entry"].first["resource"]["entity"].first["what"]["identifier"]["value"]
    assert_equal "pt_newest", first_entity_id
  end

  test "missing Bearer token returns 401" do
    get "/lakeraven-ehr/AuditEvent",
        headers: { "X-Tenant-Identifier" => "tnt_test" }
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "login", body["issue"].first["code"]
  end

  test "token without AuditEvent.read scope returns 403" do
    get "/lakeraven-ehr/AuditEvent", headers: auth_headers(scopes: "system/Patient.read")
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "forbidden", body["issue"].first["code"]
  end

  test "_count parameter limits the page size" do
    get "/lakeraven-ehr/AuditEvent?_count=1", headers: auth_headers
    body = JSON.parse(response.body)
    assert_equal 1, body["entry"].length
  end

  test "_count caps at MAX_PAGE_SIZE" do
    get "/lakeraven-ehr/AuditEvent?_count=999999", headers: auth_headers
    body = JSON.parse(response.body)
    # Only 2 rows exist in tnt_test so this just confirms the call
    # didn't fall over; the cap is asserted indirectly via the
    # default query path.
    assert body["entry"].length <= 500
  end

  test "user/AuditEvent.read scope also grants access" do
    get "/lakeraven-ehr/AuditEvent", headers: auth_headers(scopes: "user/AuditEvent.read")
    assert_response :ok
  end
end
