# frozen_string_literal: true

require "test_helper"

# Issue #588: appointment-derived Encounter ids in the patient chart FHIR bundle
# must not collide when ORWPT APPTLST supplies date-only datetimes.
class ChartEncounterAppointmentIdsTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  PATIENT_DFN = "1"
  SAME_DAY = Date.new(2026, 3, 10)
  OTHER_DAY = Date.new(2026, 4, 15)

  setup do
    setup_smart_auth(scopes: "system/*.read")
  end

  teardown do
    teardown_smart_auth
  end

  test "two same-day appointments at different clinics omit colliding appt id and use distinct urn fullUrls" do
    seed_appointments(
      { datetime: SAME_DAY, location_ien: 1, location: "Primary Care Clinic", status: "scheduled" },
      { datetime: SAME_DAY, location_ien: 2, location: "Behavioral Health Clinic", status: "kept" }
    )

    assert_colliding_appointment_encounters(chart_bundle)
  end

  test "two same-day appointments at the same clinic omit colliding appt id and use distinct urn fullUrls" do
    seed_appointments(
      { datetime: SAME_DAY, location_ien: 1, location: "Primary Care Clinic", status: "scheduled" },
      { datetime: SAME_DAY, location_ien: 1, location: "Primary Care Clinic", status: "kept" }
    )

    assert_colliding_appointment_encounters(chart_bundle)
  end

  test "a lone appointment on another day in the same bundle keeps its deterministic appt id and REST fullUrl" do
    seed_appointments(
      { datetime: SAME_DAY, location_ien: 1, location: "Primary Care Clinic", status: "scheduled" },
      { datetime: SAME_DAY, location_ien: 2, location: "Behavioral Health Clinic", status: "kept" },
      { datetime: OTHER_DAY, location_ien: 1, location: "Primary Care Clinic", status: "scheduled" }
    )

    bundle = chart_bundle
    lone = encounter_entries(bundle).find do |entry|
      entry.dig("resource", "period", "start")&.start_with?(OTHER_DAY.iso8601)
    end
    assert lone, "expected an Encounter for the lone appointment day"

    expected_id = appointment_fhir_id(PATIENT_DFN, OTHER_DAY)
    assert_equal expected_id, lone.dig("resource", "id")
    refute lone["fullUrl"].start_with?("urn:uuid:"), "lone appointment should have a REST fullUrl"
    assert_includes lone["fullUrl"], "/lakeraven-ehr/Encounter/#{expected_id}"
  end

  test "every present resource id in the chart bundle is unique per resourceType" do
    seed_appointments(
      { datetime: SAME_DAY, location_ien: 1, location: "Primary Care Clinic", status: "scheduled" },
      { datetime: SAME_DAY, location_ien: 2, location: "Behavioral Health Clinic", status: "kept" }
    )

    assert_unique_resource_ids_per_type(chart_bundle)
  end

  private

  def seed_appointments(*rows)
    RpmsRpc.client.seed_keyed_collection(:patient_appointments, PATIENT_DFN, rows)
  end

  def chart_bundle
    get "/patients/#{PATIENT_DFN}.json", headers: @headers
    assert_response :ok
    assert_equal "application/fhir+json", response.media_type
    JSON.parse(response.body)
  end

  def encounter_entries(bundle)
    bundle["entry"].select { |e| e.dig("resource", "resourceType") == "Encounter" }
  end

  def appointment_fhir_id(dfn, day)
    "appt-#{dfn}-#{day.strftime('%Y%m%d')}0000"
  end

  def assert_colliding_appointment_encounters(bundle)
    colliding_id = appointment_fhir_id(PATIENT_DFN, SAME_DAY)
    entries = encounter_entries(bundle)
    assert_equal 2, entries.length, "expected two appointment-derived Encounter entries"

    ids = entries.map { |e| e.dig("resource", "id") }.compact
    assert_equal ids.length, ids.uniq.length, "Encounter ids must be distinct when present, got #{ids.inspect}"

    entries.each do |entry|
      refute_equal colliding_id, entry.dig("resource", "id"),
                   "colliding appointment id #{colliding_id} must not be emitted"
      assert entry["fullUrl"].start_with?("urn:uuid:"),
             "colliding appointments should use urn:uuid fullUrls, got #{entry['fullUrl']}"
    end

    full_urls = entries.map { |e| e["fullUrl"] }
    assert_equal 2, full_urls.uniq.length, "Encounter fullUrls must be distinct"
  end

  def assert_unique_resource_ids_per_type(bundle)
    by_type = bundle["entry"].group_by { |e| e.dig("resource", "resourceType") }
    by_type.each do |resource_type, entries|
      ids = entries.map { |e| e.dig("resource", "id") }.compact
      duplicates = ids.group_by(&:itself).select { |_id, group| group.length > 1 }.keys
      assert_empty duplicates,
                   "duplicate #{resource_type} ids in chart bundle: #{duplicates.inspect} (all ids: #{ids.inspect})"
    end
  end
end
