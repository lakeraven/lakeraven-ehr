# frozen_string_literal: true

require "test_helper"
require_relative "../dummy/lib/lakeraven_demo_seeds"

# Spec for lakeraven-ehr#255 — FHIR referral packet for a ServiceRequest.
#
# Builder contract (implementation must satisfy):
#   Route:     GET /lakeraven-ehr/ServiceRequest/:id/$referral-bundle
#              (member operation on ServiceRequest, same style as ValueSet/$expand)
#   Bundle:    FHIR R4 type "collection"; entries include fullUrl + resource.
#   Core:      ServiceRequest (by :id) and its subject Patient are always included.
#   Sections:  Query _include-sections (comma-separated FHIR type names) narrows
#              optional sections: MedicationRequest, AllergyIntolerance, Condition,
#              Observation, Coverage, CoverageEligibilityResponse. When omitted, default
#              includes at least MedicationRequest, AllergyIntolerance, and Condition.
#              Unknown section names → 400 OperationOutcome (never silently ignored).
#   Coverage:  Coverage and/or CoverageEligibilityResponse appear only when the
#              patient has them; no placeholder entries when absent.
#   Scopes:    SMART read scope for ServiceRequest plus every resource type returned;
#              patient-bound tokens must match the referral's patient compartment.
#   Egress:    Whole bundle through render_fhir_egress / Part2EgressFilter (fail-closed 503
#              when filter returns no usable FHIR payload).
#   Source failure: Any gateway/source error for a requested section → 502 OperationOutcome
#              with no partial collection that looks complete (matches chart/export posture).
#   Eligibility: CoverageEligibilityResponse.latest_for_patient(dfn) when present (same
#              pattern as other read models); omit the type when it returns nil.
class ServiceRequestReferralBundleSpecTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  MOUNT = "/lakeraven-ehr"
  REFERRAL_IEN = "1001"
  PATIENT_DFN = "1"
  FOREIGN_PATIENT_DFN = "2"

  FULL_READ_SCOPES = [
    "system/ServiceRequest.read",
    "system/Patient.read",
    "system/MedicationRequest.read",
    "system/AllergyIntolerance.read",
    "system/Condition.read",
    "system/Observation.read",
    "system/Coverage.read",
    "system/CoverageEligibilityResponse.read"
  ].join(" ")

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
    RpmsRpc.mock! do |m|
      BASELINE_MOCK_SEEDS.call(m)
      LakeravenDemoSeeds.seed(m)
      seed_referral_for_patient!(PATIENT_DFN, ien: REFERRAL_IEN)
    end
  end

  teardown do
    teardown_smart_auth
    Lakeraven::EHR::AuditEvent.delete_all
    RpmsRpc.mock!(&BASELINE_MOCK_SEEDS)
  end

  test "GET ServiceRequest/$referral-bundle returns collection bundle with core and clinical sections" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)

    get referral_bundle_path(REFERRAL_IEN), headers: @headers

    assert_response :ok
    assert_equal "application/fhir+json", response.media_type

    body = JSON.parse(response.body)
    assert_equal "Bundle", body["resourceType"]
    assert_equal "collection", body["type"]

    entries = body.fetch("entry")
    assert entries.all? { |e| e["fullUrl"].present? && e["resource"].is_a?(Hash) },
           "every entry needs fullUrl and resource"

    types = entry_resource_types(entries)
    assert_includes types, "ServiceRequest"
    assert_includes types, "Patient"
    assert_includes types, "MedicationRequest"
    assert_includes types, "AllergyIntolerance"
    assert_includes types, "Condition"

    service_request = find_resource(entries, "ServiceRequest")
    assert_equal REFERRAL_IEN, service_request["id"]
    assert_match(%r{Patient/#{PATIENT_DFN}\z}, service_request.dig("subject", "reference"))

    assert_patient_compartment!(entries, PATIENT_DFN)
  end

  test "clinical entries belong to the referral patient only" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)
    RpmsRpc.client.seed_keyed_collection(:allergy_list, FOREIGN_PATIENT_DFN, [
      { ien: 99, allergen: "SYNTHETIC-FOREIGN-ALLERGEN", severity: "moderate" }
    ])

    get referral_bundle_path(REFERRAL_IEN), headers: @headers

    assert_response :ok
    refute_includes response.body, "SYNTHETIC-FOREIGN-ALLERGEN"
    assert_patient_compartment!(JSON.parse(response.body).fetch("entry"), PATIENT_DFN)
  end

  test "_include-sections narrows optional sections; ServiceRequest and Patient stay" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)

    get referral_bundle_path(REFERRAL_IEN),
        params: { _include_sections: "MedicationRequest" },
        headers: @headers

    assert_response :ok
    types = entry_resource_types(JSON.parse(response.body).fetch("entry"))
    assert_includes types, "ServiceRequest"
    assert_includes types, "Patient"
    assert_includes types, "MedicationRequest"
    refute_includes types, "Condition"
    refute_includes types, "AllergyIntolerance"
  end

  test "unknown _include-sections name returns 400 OperationOutcome" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)

    get referral_bundle_path(REFERRAL_IEN),
        params: { _include_sections: "MedicationRequest,NotARealSection" },
        headers: @headers

    assert_response :bad_request
    return unless response.media_type == "application/fhir+json"

    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    assert_match(/NotARealSection/i, body.dig("issue", 0, "diagnostics").to_s)
  end

  test "Coverage is included when patient has coverage and omitted when not" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)

    with_patient_coverage_type(PATIENT_DFN, "medicaid") do
      get referral_bundle_path(REFERRAL_IEN), headers: @headers
      assert_response :ok
      types = entry_resource_types(JSON.parse(response.body).fetch("entry"))
      assert_includes types, "Coverage"
    end

    with_patient_coverage_type(PATIENT_DFN, nil) do
      get referral_bundle_path(REFERRAL_IEN), headers: @headers
      assert_response :ok
      types = entry_resource_types(JSON.parse(response.body).fetch("entry"))
      refute_includes types, "Coverage"
      refute_includes response.body, '"resourceType":"Coverage"'
    end
  end

  test "CoverageEligibilityResponse is included when available and omitted when not" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)

    with_stored_eligibility_response(PATIENT_DFN) do
      get referral_bundle_path(REFERRAL_IEN), headers: @headers
      assert_response :ok
      types = entry_resource_types(JSON.parse(response.body).fetch("entry"))
      assert_includes types, "CoverageEligibilityResponse"
    end

    get referral_bundle_path(REFERRAL_IEN), headers: @headers
    assert_response :ok
    types = entry_resource_types(JSON.parse(response.body).fetch("entry"))
    refute_includes types, "CoverageEligibilityResponse"
  end

  test "unauthenticated request returns 401 with no clinical content" do
    get referral_bundle_path(REFERRAL_IEN)

    assert_response :unauthorized
    return unless response.media_type == "application/fhir+json"

    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    refute_includes response.body, "MedicationRequest"
  end

  test "token missing read scope for an included type returns 403 with no clinical content" do
    setup_smart_auth(scopes: "system/ServiceRequest.read system/Patient.read")

    get referral_bundle_path(REFERRAL_IEN), headers: @headers

    assert_response :forbidden
    refute_includes response.body, "Penicillin"
    refute_includes response.body, '"resourceType":"Condition"'
  end

  test "patient-bound token for another patient returns 403 with no clinical content" do
    setup_patient_token!(FULL_READ_SCOPES, dfn: FOREIGN_PATIENT_DFN)

    get referral_bundle_path(REFERRAL_IEN), headers: @headers

    assert_response :forbidden
    refute_includes response.body, "Anderson"
  end

  test "unknown ServiceRequest id returns 404 OperationOutcome" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)

    get referral_bundle_path("999999"), headers: @headers

    assert_equal "application/fhir+json", response.media_type
    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
  end

  test "response is filtered through Part2EgressFilter like other FHIR reads" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)
    marker = { "resourceType" => "Basic", "id" => "PART2-MARKER" }

    stub_egress_filter(->(payload) { marker }) do
      get referral_bundle_path(REFERRAL_IEN), headers: @headers
    end

    assert_response :ok
    assert_equal marker, JSON.parse(response.body)
  end

  test "Part2 egress filter returning nil yields empty 503 OperationOutcome" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)

    stub_egress_filter(->(_payload) { nil }) do
      get referral_bundle_path(REFERRAL_IEN), headers: @headers
    end

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    refute_includes response.body, '"resourceType":"Patient"'
  end

  test "successful read is audited like other FHIR reads" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)

    assert_difference -> { Lakeraven::EHR::AuditEvent.count }, 1 do
      get referral_bundle_path(REFERRAL_IEN), headers: @headers
    end

    event = Lakeraven::EHR::AuditEvent.recent.first
    assert_equal "rest", event.event_type
    assert_equal "R", event.action
    assert_equal "0", event.outcome
    assert_equal "ServiceRequest", event.entity_type
    assert_equal REFERRAL_IEN, event.entity_identifier
  end

  test "a failing clinical source returns 502 OperationOutcome without a partial collection" do
    setup_smart_auth(scopes: FULL_READ_SCOPES)
    gateway = Lakeraven::EHR::MedicationRequestGateway.singleton_class
    original = gateway.instance_method(:for_patient)

    gateway.define_method(:for_patient) do |*_args|
      raise Lakeraven::EHR::SupplementalProviderError, "medication source unavailable"
    end

    get referral_bundle_path(REFERRAL_IEN), headers: @headers

    assert_response :internal_server_error
    body = JSON.parse(response.body)
    assert_equal "OperationOutcome", body["resourceType"]
    refute_includes response.body, '"type":"collection"'
    refute_includes response.body, '"resourceType":"MedicationRequest"'
  ensure
    gateway.define_method(:for_patient, original)
  end

  private

  def referral_bundle_path(ien)
    "#{MOUNT}/ServiceRequest/#{ien}/$referral-bundle"
  end

  def seed_referral_for_patient!(dfn, ien:)
    RpmsRpc.client.seed_keyed_collection(:referral_search, dfn.to_s, [
      { ien: ien, patient_dfn: dfn.to_i, status: "A", type: "C",
        date: Date.new(2026, 1, 15), provider: "MARTINEZ,SARAH",
        purpose: "Cardiology consult", referral_number: "2026-#{ien}" }
    ])
  end

  def entry_resource_types(entries)
    entries.map { |e| e.dig("resource", "resourceType") }.compact
  end

  def find_resource(entries, type)
    entries.find { |e| e.dig("resource", "resourceType") == type }.fetch("resource")
  end

  def assert_patient_compartment!(entries, dfn)
    entries.each do |entry|
      resource = entry["resource"]
      next unless resource.is_a?(Hash)

      type = resource["resourceType"]
      next if type == "ServiceRequest"

      subject_ref = resource.dig("subject", "reference") || resource.dig("patient", "reference")
      if subject_ref
        assert_match(%r{Patient/#{dfn}\z}, subject_ref,
                     "#{type} must belong to patient #{dfn}, got #{subject_ref}")
      elsif type == "Patient"
        assert_equal dfn, resource["id"].to_s
      end
    end
  end

  def setup_patient_token!(scopes, dfn:)
    teardown_smart_auth
    app = Doorkeeper::Application.create!(
      name: "patient-client", redirect_uri: "https://example.test/cb",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: scopes, expires_in: 3600, resource_owner_id: dfn.to_i
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def with_patient_coverage_type(dfn, coverage_type)
    patient_model = Lakeraven::EHR::Patient.singleton_class
    original = patient_model.instance_method(:find_by_dfn)
    patient_model.define_method(:find_by_dfn) do |requested_dfn|
      patient = original.bind(Lakeraven::EHR::Patient).call(requested_dfn)
      if patient && requested_dfn.to_s == dfn.to_s
        patient.coverage_type = coverage_type
      end
      patient
    end
    yield
  ensure
    patient_model.define_method(:find_by_dfn, original)
  end

  def with_stored_eligibility_response(dfn)
    response = Lakeraven::EHR::CoverageEligibilityResponse.new(
      patient_dfn: dfn,
      status: "enrolled",
      coverage_type: "medicaid"
    )
    model = Lakeraven::EHR::CoverageEligibilityResponse.singleton_class
    model.define_method(:latest_for_patient) do |requested_dfn|
      response if requested_dfn.to_s == dfn.to_s
    end
    yield
  ensure
    model.remove_method(:latest_for_patient) if model.method_defined?(:latest_for_patient)
  end

  def stub_egress_filter(implementation)
    filter = Lakeraven::EHR::Part2EgressFilter.singleton_class
    original = filter.instance_method(:call)
    filter.define_method(:call) { |payload| implementation.call(payload) }
    yield
  ensure
    filter.define_method(:call, original)
  end
end
