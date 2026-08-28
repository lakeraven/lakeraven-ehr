# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"

# Read-only, AUTHENTICATED demo patient chart (issue #452).
#
# Exercises the content-negotiated /chart/:dfn endpoint against the test/dummy
# host with the shared synthetic seed set — the SAME data the SPIKE dev
# initializer loads. Installs a fully-seeded mock for the test and restores
# the suite-wide shared mock afterward so global state stays clean.
#
# Auth is enforced for BOTH representations (HTML + FHIR JSON): SMART bearer
# token (Doorkeeper), per-resource read scope, and patient-context binding.
class DemoPatientChartTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    @original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
    setup_smart_auth(scopes: "system/*.read") # @headers => full read token
  end

  teardown do
    teardown_smart_auth
    RpmsRpc.configure { |c| c.client = @original_client }
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def token_with(scopes:, resource_owner_id: nil)
    app = Doorkeeper::Application.create!(
      name: "scoped", redirect_uri: "https://example.test/callback",
      scopes: scopes, confidential: true
    )
    Doorkeeper::AccessToken.create!(
      application: app, scopes: scopes, resource_owner_id: resource_owner_id, expires_in: 3600
    )
  end

  # -- HTML representation (authenticated) -------------------------------------

  test "HTML chart renders the patient banner and every clinical section" do
    get "/chart/1", headers: @headers

    assert_response :ok
    assert_equal "text/html", response.media_type
    body = response.body

    assert_includes body, "Lakeraven EHR"
    assert_includes body, "Alice Anderson"
    assert_includes body, "Type 2 diabetes mellitus"
    assert_includes body, "E11.9"
    assert_includes body, "Lisinopril 10mg"
    assert_includes body, "Metformin 500mg"
    assert_includes body, "Penicillin"
    assert_includes body, "Shellfish"
    assert_includes body, "128/82"
    assert_includes body, "COVID-19 Vaccine"
    assert_includes body, "Riverbend Family Health Clinic"
    assert_includes body, "View as FHIR"
  end

  # -- FHIR JSON representation (authenticated) --------------------------------

  test "chart .json returns a FHIR Bundle with the FHIR content type" do
    get "/chart/1.json", headers: @headers

    assert_response :ok
    assert_equal "application/fhir+json", response.media_type

    bundle = JSON.parse(response.body)
    assert_equal "Bundle", bundle["resourceType"]
    assert_equal "searchset", bundle["type"]
    assert bundle["total"].to_i.positive?

    resource_types = bundle["entry"].map { |e| e.dig("resource", "resourceType") }
    %w[Patient Condition MedicationRequest AllergyIntolerance Observation].each do |type|
      assert_includes resource_types, type, "Bundle should contain a #{type}"
    end
  end

  test "Accept: application/fhir+json also yields the Bundle" do
    get "/chart/1", headers: @headers.merge("Accept" => "application/fhir+json")

    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
  end

  # -- FHIR Bundle conformance polish ------------------------------------------

  test "FHIR Bundle carries id, meta.lastUpdated, self link, and per-entry fullUrl" do
    get "/chart/1.json", headers: @headers
    bundle = JSON.parse(response.body)

    assert bundle["id"].present?, "Bundle should have an id"
    assert bundle.dig("meta", "lastUpdated").present?, "Bundle should have meta.lastUpdated"
    assert_equal bundle["entry"].length, bundle["total"]

    self_link = Array(bundle["link"]).find { |l| l["relation"] == "self" }
    assert self_link, "Bundle should have a self link"
    assert self_link["url"].present?

    assert bundle["entry"].all? { |e| e["fullUrl"].present? }, "every entry needs a fullUrl"
  end

  test "AllergyIntolerance and Encounter entries carry an id with resolvable (non-urn) fullUrls" do
    get "/chart/1.json", headers: @headers
    bundle = JSON.parse(response.body)

    %w[AllergyIntolerance Encounter].each do |type|
      entries = bundle["entry"].select { |e| e.dig("resource", "resourceType") == type }
      assert entries.any?, "expected at least one #{type} entry"

      entries.each do |e|
        assert e.dig("resource", "id").present?, "#{type} resource should carry an id"
        refute e["fullUrl"].start_with?("urn:uuid:"), "#{type} fullUrl should be resolvable, got #{e['fullUrl']}"
        assert_includes e["fullUrl"], "/fhir/#{type}/", "#{type} fullUrl should be a REST URL"
      end
    end

    # Encounter id is deterministic/stable across requests.
    enc_id = bundle["entry"].find { |e| e.dig("resource", "resourceType") == "Encounter" }.dig("resource", "id")
    get "/chart/1.json", headers: @headers
    enc_id_again = JSON.parse(response.body)["entry"]
      .find { |e| e.dig("resource", "resourceType") == "Encounter" }.dig("resource", "id")
    assert_equal enc_id, enc_id_again, "Encounter id should be stable across requests"
  end

  # -- Authentication: fail closed, no token -----------------------------------

  test "no token -> 401 for HTML, and NOT a FHIR JSON body" do
    get "/chart/1"

    assert_response :unauthorized
    refute_equal "application/fhir+json", response.media_type
  end

  test "no token -> 401 FHIR OperationOutcome for .json" do
    get "/chart/1.json"

    assert_response :unauthorized
    assert_equal "application/fhir+json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
  end

  # -- Authorization: scope --------------------------------------------------

  test "token that cannot read Patient -> 403" do
    token = token_with(scopes: "system/Observation.read")
    get "/chart/1.json", headers: bearer(token)

    assert_response :forbidden
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  end

  # -- Authorization: patient context ------------------------------------------

  test "patient-scoped token bound to a DIFFERENT patient -> 403" do
    token = token_with(scopes: "patient/*.read", resource_owner_id: 2)
    get "/chart/1.json", headers: bearer(token)

    assert_response :forbidden
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  end

  test "patient-scoped token bound to THIS patient -> 200" do
    token = token_with(scopes: "patient/*.read", resource_owner_id: 1)
    get "/chart/1.json", headers: bearer(token)

    assert_response :ok
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
  end

  # -- Audit -------------------------------------------------------------------

  test "successful access records an AuditEvent" do
    assert_difference -> { Lakeraven::EHR::AuditEvent.count }, 1 do
      get "/chart/1.json", headers: @headers
    end
    assert_response :ok
  end

  # -- Dev-only demo bypass is impossible in test ------------------------------

  test "demo bypass does NOT apply in the test environment" do
    ENV["CHART_DEMO_OPEN"] = "1"
    get "/chart/1.json" # no token

    assert_response :unauthorized
    assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
  ensure
    ENV.delete("CHART_DEMO_OPEN")
  end

  # -- Not found (still an OperationOutcome, once authenticated) ----------------

  test "unknown patient returns 404 as OperationOutcome for FHIR requests" do
    get "/chart/99999.json", headers: @headers

    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "not-found", body["issue"].first["code"]
  end
end
