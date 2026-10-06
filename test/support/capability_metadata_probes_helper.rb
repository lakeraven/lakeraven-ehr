# frozen_string_literal: true

# HTTP probes for /metadata conformance — seeds only surfaces that exist on main
# (RpmsRpc keyed collections, CarePlanStore, DiagnosticReportStore, AuditEvent).
# Intentionally does NOT touch MedicationStore.
module CapabilityMetadataProbesHelper
  FHIR_PREFIX = "/lakeraven-ehr"
  METADATA_PATH = "#{FHIR_PREFIX}/metadata"

  OMIT_FROM_CAPABILITY_METADATA_CROSSWALK = %w[
    CoverageEligibilityRequest Procedure
  ].freeze

  CAPABILITY_PROBE_ALLERGEN = "Penicillin"
  CAPABILITY_PROBE_APPOINTMENT_ON = Date.new(2026, 8, 12)

  def install_capability_read_probe_fixtures!
    @instance_read_probes = {}

    client = RpmsRpc.client
    client.seed_keyed_collection(:allergy_list, "1", [
      { allergen: CAPABILITY_PROBE_ALLERGEN, reaction: "Hives", severity: "moderate" }
    ])
    client.seed_keyed_collection(:patient_appointments, "1", [
      { datetime: CAPABILITY_PROBE_APPOINTMENT_ON.to_datetime, location_ien: 1,
        location: "Primary Care Clinic", status: "CHECKED OUT" }
    ])
    client.seed_keyed_collection(:medication_list, "1", [
      { ien: 9001, drug_name: "Lisinopril 10mg", sig: "1 tab PO daily", status: "active" }
    ])

    CarePlanStore.instance.add(CarePlan.new(
      ien: "cp-capability-probe", patient_dfn: "1", title: "Capability probe care plan",
      status: "active", intent: "plan"
    ))
    DiagnosticReportStore.instance.add(DiagnosticReport.new(
      ien: "dr-capability-probe", patient_dfn: "1", category: "LAB",
      code: "4548-4", code_display: "Hemoglobin A1c", status: "final"
    ))

    audit = AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      entity_type: "Patient", entity_identifier: "1"
    )
    @capability_audit_event_id = audit.id

    allergy_id = "allergy-1-penicillin"
    encounter_id = Encounter.send(
      :appointment_id, "1", { datetime: CAPABILITY_PROBE_APPOINTMENT_ON }
    )

    @instance_read_probes.merge!(
      "Patient" => "#{FHIR_PREFIX}/Patient/1",
      "Practitioner" => "#{FHIR_PREFIX}/Practitioner/101",
      "Organization" => "#{FHIR_PREFIX}/Organization/1",
      "Location" => "#{FHIR_PREFIX}/Location/1",
      "AllergyIntolerance" => "#{FHIR_PREFIX}/AllergyIntolerance/#{allergy_id}",
      "Encounter" => "#{FHIR_PREFIX}/Encounter/#{encounter_id}",
      "CarePlan" => "#{FHIR_PREFIX}/CarePlan/cp-capability-probe",
      "DiagnosticReport" => "#{FHIR_PREFIX}/DiagnosticReport/dr-capability-probe",
      "AuditEvent" => "#{FHIR_PREFIX}/AuditEvent/#{audit.id}"
    )
  end

  def teardown_capability_read_probe_fixtures!
    client = RpmsRpc.client
    client.seed_keyed_collection(:allergy_list, "1", [])
    client.seed_keyed_collection(:patient_appointments, "1", [])
    client.seed_keyed_collection(:medication_list, "1", [])

    CarePlanStore.reset_instance!
    DiagnosticReportStore.reset_instance!

    if @capability_audit_event_id
      AuditEvent.where(id: @capability_audit_event_id).delete_all
    end
  end

  def fetch_capability_statement_unauthenticated
    get METADATA_PATH
    assert_response :ok, "metadata must be reachable to drive advertised-interaction probes"
    JSON.parse(response.body)
  end

  def routed_fhir_resource_types_for_metadata
    types = Set.new
    Lakeraven::EHR::Engine.routes.routes.each do |route|
      next unless %w[GET HEAD].include?(route.verb)

      type = fhir_path_resource_type(route.path.spec.to_s)
      next if type.nil? || OMIT_FROM_CAPABILITY_METADATA_CROSSWALK.include?(type)

      types << type
    end
    types.to_a.sort
  end

  def fhir_path_resource_type(path_spec)
    path_spec.split("/").find { |part| part.match?(/\A[A-Z][A-Za-z]+\z/) }
  end

  def oauth_scope_strings_in(capability)
    security = capability.fetch("rest").flat_map { |r| Array(r["security"]) }
    security.to_json.scan(%r{(?:patient|user|system)/[^\s"\\]+})
  end

  def assert_member_read_route!(type)
    probe_path = "#{FHIR_PREFIX}/#{type}/capability-route-probe"
    recognized = Rails.application.routes.recognize_path(probe_path, method: :get)
    assert recognized[:controller].present?,
      "CapabilityStatement lists read on #{type} but no member GET route exists"
  rescue ActionController::RoutingError
    flunk "CapabilityStatement lists read on #{type} but no member GET route exists"
  end

  def assert_advertised_read_on_wire!(type)
    path = @instance_read_probes[type]
    unless path
      assert_member_read_route!(type)
      return
    end

    get path, headers: @headers
    assert_equal "application/fhir+json", response.media_type,
      "#{type} read must return FHIR JSON, not HTML or plain JSON"
    assert_equal 200, response.status,
      "#{type} read advertised in metadata must succeed for a seeded instance"
    assert_equal type, JSON.parse(response.body)["resourceType"]
  end

  def assert_advertised_search_on_wire!(type)
    path, params = capability_search_probe(type)
    assert path.present?,
      "CapabilityStatement lists search-type on #{type} but this spec has no HTTP probe"

    get path, params: params, headers: @headers
    assert_equal 200, response.status,
      "#{type}? search advertised in metadata must return 200, not 401/404 routing"
    assert_equal "Bundle", JSON.parse(response.body)["resourceType"],
      "#{type} search must return a FHIR Bundle"
  end

  def capability_search_probe(type)
    case type
    when "Patient" then [ "#{FHIR_PREFIX}/Patient", { name: "Anderson" } ]
    when "Practitioner" then [ "#{FHIR_PREFIX}/Practitioner", { name: "MARTINEZ" } ]
    when "Medication" then [ "#{FHIR_PREFIX}/Medication", {} ]
    when "Measure", "MeasureReport", "AuditEvent", "ValueSet"
      [ "#{FHIR_PREFIX}/#{type}", {} ]
    when "Organization", "Location" then [ nil, nil ]
    else
      [ "#{FHIR_PREFIX}/#{type}", { patient: "1" } ]
    end
  end
end
