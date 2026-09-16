# frozen_string_literal: true

require "test_helper"

# The audit row must NAME the record it touched, and the concern is the ONE
# owner of that rule (round-2 gate on #512, consolidated review): a FHIR
# clinical search identifies its patient with `?patient=…` (reference form
# `Patient/<dfn>` included), a FHIR search-by-id uses `?_id=…`, and neither
# was in the entity chain — so those reads recorded a NULL entity, and
# `/audit-review?entity=<dfn>` (and the §164.528 export keyed on
# entity_identifier) read EMPTY for a chart that was just opened. Empty
# reads as "nobody opened this chart": absence of data as determination.
class AuditEntityIdentityTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    Lakeraven::EHR::AuditEvent.delete_all
    setup_smart_auth(scopes: "system/*.read")
  end

  test "a FHIR search by ?patient= records the patient as the entity, not null" do
    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event, "a clinical search left no audit trail"
    assert_equal "Patient", event.entity_type,
      "a ?patient= search recorded the wrong entity type — the reference points at the wrong record"
    assert_equal "1", event.entity_identifier,
      "a ?patient= search recorded a null entity; a §164.528 export keyed on the DFN reads empty"
  end

  test "the FHIR reference form ?patient=Patient/1 records the same entity" do
    get "/lakeraven-ehr/Observation", params: { patient: "Patient/1" }, headers: @headers
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal [ "Patient", "1" ], [ event.entity_type, event.entity_identifier ]
  end

  test "a Patient search by ?_id= records the patient, not a null entity" do
    get "/lakeraven-ehr/Patient", params: { _id: "1" }, headers: @headers
    assert_response :ok

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    refute_nil event
    assert_equal "Patient", event.entity_type
    assert_equal "1", event.entity_identifier,
      "a ?_id= search recorded a null entity (patients_controller searches on _id)"
  end

  test "a direct resource read still records its own resource entity" do
    get "/lakeraven-ehr/Patient/1", headers: @headers

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal [ "Patient", "1" ], [ event.entity_type, event.entity_identifier ]
  end
end
