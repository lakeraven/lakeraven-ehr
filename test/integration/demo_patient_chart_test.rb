# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"

# Read-only demo patient chart (issue #452).
#
# Exercises the content-negotiated /chart/:dfn endpoint against the test/dummy
# host with the shared synthetic seed set — the SAME data the SPIKE dev
# initializer loads. Installs a fully-seeded mock for the test and restores
# the suite-wide shared mock afterward so global state stays clean.
class DemoPatientChartTest < ActionDispatch::IntegrationTest
  setup do
    @original_client = RpmsRpc.configuration.client
    RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
  end

  teardown do
    RpmsRpc.configure { |c| c.client = @original_client }
  end

  # -- HTML representation -----------------------------------------------------

  test "HTML chart renders the patient banner and every clinical section" do
    get "/chart/1"

    assert_response :ok
    assert_equal "text/html", response.media_type
    body = response.body

    # No auth required — a browser hit lands straight on the chart.
    assert_includes body, "Lakeraven EHR"
    assert_includes body, "Alice Anderson" # display_name (last,first -> first last)

    # Problem list
    assert_includes body, "Type 2 diabetes mellitus"
    assert_includes body, "E11.9"
    # Medications
    assert_includes body, "Lisinopril 10mg"
    assert_includes body, "Metformin 500mg"
    # Allergies (alert strip + detail)
    assert_includes body, "Penicillin"
    assert_includes body, "Shellfish"
    # Vitals
    assert_includes body, "128/82"
    # Immunizations
    assert_includes body, "COVID-19 Vaccine"
    # Encounters
    assert_includes body, "Riverbend Family Health Clinic"

    # FHIR affordance is visible on the page.
    assert_includes body, "View as FHIR"
  end

  # -- FHIR JSON representation (.json extension is the must-have) --------------

  test "chart .json returns a FHIR Bundle with the FHIR content type" do
    get "/chart/1.json"

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
    get "/chart/1", headers: { "Accept" => "application/fhir+json" }

    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
  end

  # -- Not found ---------------------------------------------------------------

  test "unknown patient returns 404 as OperationOutcome for FHIR requests" do
    get "/chart/99999.json"

    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_equal "not-found", body["issue"].first["code"]
  end
end
