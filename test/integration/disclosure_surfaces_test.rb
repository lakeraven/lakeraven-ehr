# frozen_string_literal: true

require "test_helper"

# Closing the egress paths December does not need (#522): bulk EHI export,
# C-CDA transitions of care and the FHIR REST API (audit
# docs/compliance/part2-disclosure-surface-audit.md §1 paths 2–4, §5(a)).
#
# The host names the surfaces it wants OPEN in
# Rails.application.config.x.lakeraven_ehr.open_disclosure_surfaces. A closed
# surface answers 404 BEFORE authentication and BEFORE any broker call — a
# valid token with the right scopes gets the same 404 as no token — and the
# body carries no clinical content. The HTML chart (path 1), /metadata and
# the SMART discovery document are never governed by this switch.
#
# The dummy app's test environment opens all three so the rest of the suite
# keeps working; every test here sets the value itself and restores it.
class DisclosureSurfacesTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  PATIENT_DFN = "1"
  # Synthetic BASELINE_MOCK_SEEDS patient (test/test_helper.rb): "Anderson,Alice".
  PATIENT_NAME_PARTS = %w[Anderson Alice].freeze
  ALL_SURFACES = %i[fhir_api bulk_export ccda].freeze

  setup do
    @config = Rails.application.config.x.lakeraven_ehr
    @had_key = @config.key?(:open_disclosure_surfaces)
    @original_surfaces = @config.open_disclosure_surfaces
    # Read AND write scopes: a closed surface must 404 even for a token that
    # would otherwise be allowed through.
    setup_smart_auth(scopes: "system/*.read system/*.write")
    Lakeraven::EHR::ExportsController.reset_store!
  end

  teardown do
    if @had_key
      @config.open_disclosure_surfaces = @original_surfaces
    else
      @config.delete(:open_disclosure_surfaces)
    end
    teardown_smart_auth
    Lakeraven::EHR::ExportsController.reset_store!
  end

  def open_surfaces(value)
    @config.open_disclosure_surfaces = value
  end

  # -- Requests, one per route the switch governs ------------------------------

  def fhir_patient_read(headers = @headers)
    get "/lakeraven-ehr/Patient/#{PATIENT_DFN}", headers: headers
  end

  def fhir_condition_search(headers = @headers)
    get "/lakeraven-ehr/Condition", params: { patient: PATIENT_DFN }, headers: headers
  end

  def chart_json(headers = @headers)
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}.json", headers: headers
  end

  def chart_fhir_accept(headers = @headers)
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: headers.merge("Accept" => "application/fhir+json")
  end

  def chart_html(headers = @headers)
    get "/lakeraven-ehr/patients/#{PATIENT_DFN}", headers: headers
  end

  def export_kickoff(headers = @headers)
    post "/lakeraven-ehr/exports",
      params: { export_type: "patient", patient_dfn: PATIENT_DFN }, headers: headers
  end

  def transition_of_care(headers = @headers)
    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: PATIENT_DFN }, headers: headers
  end

  # Kick off an export while bulk_export is open and return the status URL
  # and the Patient NDJSON file path, so the closed-path tests have a real,
  # completed export to be refused.
  def completed_export_paths
    open_surfaces [ :bulk_export ]
    export_kickoff
    assert_response :accepted, "setup: POST /exports must succeed while bulk_export is open"
    export_id = JSON.parse(response.body).fetch("id")

    get "/lakeraven-ehr/exports/#{export_id}", headers: @headers
    assert_response :ok, "setup: the export must complete while bulk_export is open"
    patient_file = JSON.parse(response.body).fetch("output").find { |f| f["type"] == "Patient" }
    assert patient_file, "setup: the manifest must list a Patient file"

    [ "/lakeraven-ehr/exports/#{export_id}", URI.parse(patient_file.fetch("url")).path ]
  end

  # -- Assertions ---------------------------------------------------------------

  def assert_closed(label)
    assert_response :not_found, "#{label} should be 404 while its surface is closed (got #{response.status})"
    assert_no_clinical_content(label)
  end

  def assert_no_clinical_content(label)
    body = response.body
    PATIENT_NAME_PARTS.each do |part|
      refute_includes body, part, "#{label}: a closed surface must not carry the patient's name"
    end
    refute_match(/"resourceType"\s*:\s*"Patient"/, body, "#{label}: a closed surface must not carry a Patient resource")
    refute_match(/"resourceType"\s*:\s*"Bundle"/, body, "#{label}: a closed surface must not carry a Bundle")
    refute_includes body, "ClinicalDocument", "#{label}: a closed surface must not carry a C-CDA"
  end

  def assert_no_broker_calls_since(before, label)
    calls = RpmsRpc.client.received_calls.length - before
    assert_equal 0, calls, "#{label}: a closed surface must answer before any broker call (#{calls} made)"
  end

  # Run a request against a closed surface and assert every closed-surface
  # property at once.
  def assert_closed_request(label)
    before = RpmsRpc.client.received_calls.length
    yield
    assert_closed(label)
    assert_no_broker_calls_since(before, label)
  end

  # ============================================================================
  # (a) Everything closed (value nil)
  # ============================================================================

  test "nil: FHIR Patient read is 404 with no broker call and no clinical content" do
    open_surfaces nil
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
  end

  test "nil: FHIR Condition search is 404 with no broker call and no clinical content" do
    open_surfaces nil
    assert_closed_request("GET /Condition?patient=") { fhir_condition_search }
  end

  test "nil: the chart's .json representation is 404 with no broker call and no Bundle" do
    open_surfaces nil
    assert_closed_request("GET /patients/:dfn.json") { chart_json }
  end

  test "nil: the chart with Accept: application/fhir+json is 404 with no broker call and no Bundle" do
    open_surfaces nil
    assert_closed_request("GET /patients/:dfn Accept: fhir+json") { chart_fhir_accept }
  end

  test "nil: POST /exports is 404 with no broker call" do
    open_surfaces nil
    assert_closed_request("POST /exports") { export_kickoff }
  end

  test "nil: GET /exports/:id is 404 for a completed export with no broker call" do
    status_path, _file_path = completed_export_paths
    open_surfaces nil
    assert_closed_request("GET /exports/:id") { get status_path, headers: @headers }
  end

  test "nil: DELETE /exports/:id is 404 for a completed export with no broker call" do
    status_path, _file_path = completed_export_paths
    open_surfaces nil
    assert_closed_request("DELETE /exports/:id") { delete status_path, headers: @headers }
  end

  test "nil: GET /exports/:id/files/:file_name is 404 for a completed export and serves no bytes" do
    _status_path, file_path = completed_export_paths
    open_surfaces nil
    assert_closed_request("GET /exports/:id/files/patient.ndjson") { get file_path, headers: @headers }
    refute_equal "application/fhir+ndjson", response.media_type
  end

  test "nil: POST /transitions_of_care is 404 with no broker call and no C-CDA" do
    open_surfaces nil
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
    refute_equal "application/xml", response.media_type
  end

  # Closed means closed BEFORE authentication: an unauthenticated request gets
  # the same 404, not a 401 that confirms the surface exists.
  test "nil: a closed surface answers 404, not 401, to a request with no token" do
    open_surfaces nil
    assert_closed_request("GET /Patient/:dfn no token") { fhir_patient_read({}) }
    assert_closed_request("POST /exports no token") { export_kickoff({}) }
    assert_closed_request("POST /transitions_of_care no token") { transition_of_care({}) }
  end

  # ============================================================================
  # (b) Everything closed: the HTML chart and the metadata endpoints stay on
  # ============================================================================

  test "nil: the HTML chart still renders the patient" do
    open_surfaces nil
    chart_html
    assert_response :ok
    assert_equal "text/html", response.media_type
    assert_includes response.body, "Anderson"
    assert_includes response.body, "Alice"
  end

  test "nil: GET /metadata still answers 200" do
    open_surfaces nil
    get "/lakeraven-ehr/metadata"
    assert_response :ok
    assert_equal "CapabilityStatement", JSON.parse(response.body)["resourceType"]
  end

  test "nil: GET /.well-known/smart-configuration still answers 200" do
    open_surfaces nil
    get "/lakeraven-ehr/.well-known/smart-configuration"
    assert_response :ok
    assert JSON.parse(response.body).key?("token_endpoint")
  end

  # ============================================================================
  # (c) Only fhir_api open (String entry)
  # ============================================================================

  test "fhir_api only: FHIR Patient read works" do
    open_surfaces [ "fhir_api" ]
    fhir_patient_read
    assert_response :ok
    assert_equal "Patient", JSON.parse(response.body)["resourceType"]
  end

  test "fhir_api only: the chart's FHIR JSON representation works" do
    open_surfaces [ "fhir_api" ]
    chart_json
    assert_response :ok
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"]
  end

  test "fhir_api only: POST /exports is 404" do
    open_surfaces [ "fhir_api" ]
    assert_closed_request("POST /exports") { export_kickoff }
  end

  test "fhir_api only: POST /transitions_of_care is 404" do
    open_surfaces [ "fhir_api" ]
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  # ============================================================================
  # (d) Only bulk_export open (Symbol entry)
  # ============================================================================

  test "bulk_export only: POST /exports works" do
    open_surfaces [ :bulk_export ]
    export_kickoff
    assert_response :accepted
    assert JSON.parse(response.body)["id"].present?
  end

  test "bulk_export only: FHIR Patient read is 404" do
    open_surfaces [ :bulk_export ]
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
  end

  test "bulk_export only: the chart's FHIR JSON representation is 404" do
    open_surfaces [ :bulk_export ]
    assert_closed_request("GET /patients/:dfn.json") { chart_json }
  end

  test "bulk_export only: POST /transitions_of_care is 404" do
    open_surfaces [ :bulk_export ]
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  # ============================================================================
  # (e) Only ccda open
  # ============================================================================

  test "ccda only: POST /transitions_of_care works" do
    open_surfaces [ :ccda ]
    transition_of_care
    assert_response :created
    assert_equal "application/xml", response.media_type
    assert_includes response.body, "ClinicalDocument"
  end

  test "ccda only: FHIR Patient read is 404" do
    open_surfaces [ :ccda ]
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
  end

  test "ccda only: POST /exports is 404" do
    open_surfaces [ :ccda ]
    assert_closed_request("POST /exports") { export_kickoff }
  end

  # ============================================================================
  # (f) A non-Array value closes all three
  # ============================================================================

  test "true closes all three surfaces" do
    open_surfaces true
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
    assert_closed_request("POST /exports") { export_kickoff }
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  test "a bare surface name String closes all three surfaces" do
    open_surfaces "fhir_api"
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
    assert_closed_request("POST /exports") { export_kickoff }
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  test "an unknown name opens nothing" do
    open_surfaces [ :everything ]
    assert_closed_request("GET /Patient/:dfn") { fhir_patient_read }
    assert_closed_request("POST /exports") { export_kickoff }
    assert_closed_request("POST /transitions_of_care") { transition_of_care }
  end

  # ============================================================================
  # The switch is read per request
  # ============================================================================

  test "the value is read per request: closing fhir_api takes effect on the next request" do
    open_surfaces ALL_SURFACES
    fhir_patient_read
    assert_response :ok

    open_surfaces nil
    assert_closed_request("GET /Patient/:dfn after closing") { fhir_patient_read }

    open_surfaces [ :fhir_api ]
    fhir_patient_read
    assert_response :ok
  end
end
