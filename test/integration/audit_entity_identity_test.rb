# frozen_string_literal: true

require "test_helper"

# The audit row must NAME the record it touched. A FHIR clinical search
# identifies its patient with `?patient=…`, not `:dfn` — so a row that keys
# only off :dfn/:ien/:id records a NULL entity for every search, and
# `/audit-review?entity=<dfn>` comes back empty. Empty reads as "nobody
# opened this chart": absence of data presented as determination (S11 on
# #507).
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
      "a ?patient= search recorded a null entity; /audit-review?entity=1 would come back empty"
  end

  test "the recorded search is findable by the patient it read" do
    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers

    found = Lakeraven::EHR::AuditEvent.review(entity: "1")
    assert found.any?, "the chart read cannot be found by the patient whose chart was read"
  end

  test "a direct resource read still records its own resource entity" do
    get "/lakeraven-ehr/Patient/1", headers: @headers

    event = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal "Patient", event.entity_type
    assert_equal "1", event.entity_identifier
  end
end
