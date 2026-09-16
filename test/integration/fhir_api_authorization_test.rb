# frozen_string_literal: true

require "test_helper"

# Authorization boundaries of the FHIR API itself, independent of any browser
# session. Every test here failed before the corresponding fix.
#
# Three defect classes, each found by asking the same question through a door
# nobody had checked:
#
#   * a read scope authorized a write, because the base filter called
#     can_read? for every verb;
#   * a patient-bound token read other patients, because indexes REQUIRED a
#     patient parameter and then trusted it — and writes were not bound at all;
#   * a bulk export's bytes were served with no ownership check, while the
#     status endpoint beside it had one.
class FhirApiAuthorizationTest < ActionDispatch::IntegrationTest
  # -- a read scope must not authorize a write ----------------------------

  test "a read-only token cannot POST a C-CDA import" do
    setup_auth(scopes: "system/*.read")

    post "/lakeraven-ehr/ccda_imports", params: { patient_dfn: "1" },
      headers: @headers.merge("CONTENT_TYPE" => "application/xml"),
      env: { "RAW_POST_DATA" => "<ClinicalDocument/>" }
    assert_response :forbidden
  end

  test "a read-only token cannot create an export" do
    setup_auth(scopes: "system/*.read")

    post "/lakeraven-ehr/exports", params: { export_type: "patient" }, headers: @headers
    assert_response :forbidden
  end

  test "a read-only token cannot delete an export" do
    setup_auth(scopes: "system/*.read")

    delete "/lakeraven-ehr/exports/anything", headers: @headers
    assert_response :forbidden
  end

  test "a read-only token cannot request an eligibility check" do
    setup_auth(scopes: "system/*.read")

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" }, headers: @headers
    assert_response :forbidden
  end

  test "a read-only token cannot generate a transition-of-care document" do
    setup_auth(scopes: "system/*.read")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :forbidden
  end

  # -- ...and a write scope must not authorize a read ---------------------

  # TransitionsOfCare and Export are reads shaped as POSTs. Dispatching purely
  # on verb gets them exactly backwards: they start requiring write and stop
  # requiring read, so a write-only token reads a chart it cannot reach
  # through any read endpoint.
  test "a write-only token cannot generate a transition of care" do
    setup_auth(scopes: "system/*.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :forbidden
    refute_includes response.body, "Anderson"
  end

  test "a write-only token cannot create an export" do
    setup_auth(scopes: "system/*.write")

    post "/lakeraven-ehr/exports", params: { export_type: "patient" }, headers: @headers
    assert_response :forbidden
  end

  # This route's declaration was covered by nothing: deleting it left the suite
  # green, while the same deletion on the other two correctly reddened tests.
  test "a write-only token cannot request an eligibility determination" do
    setup_auth(scopes: "system/*.write")

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" }, headers: @headers
    assert_response :forbidden
  end

  # B1: the disclosed types are what must be readable — not a pseudo-resource
  # named after the controller class. A token scoped to the route's own name
  # satisfied the old check and still extracted the patient's demographics.
  test "a token scoped to the route name cannot extract a chart through it" do
    setup_auth(scopes: "system/TransitionsOfCare.read system/TransitionsOfCare.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers

    assert_response :forbidden
    refute_includes response.body, "Anderson"
  end

  test "a token scoped to the route name cannot extract coverage through it" do
    setup_auth(scopes: "system/CoverageEligibilityRequest.read " \
                       "system/CoverageEligibilityRequest.write")

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" }, headers: @headers

    assert_response :forbidden
  end

  test "a token that can read the disclosed types may still use the route" do
    setup_auth(scopes: "system/Patient.read system/AllergyIntolerance.read " \
                       "system/Condition.read system/MedicationRequest.read " \
                       "system/TransitionsOfCare.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :created
  end

  # B2: the one patient-naming write with no compartment declaration.
  test "a patient-bound token cannot import a C-CDA for another patient" do
    setup_auth(scopes: "patient/*.read patient/*.write", resource_owner_id: 999)

    post "/lakeraven-ehr/ccda_imports", params: { patient_dfn: "1" },
      headers: @headers.merge("CONTENT_TYPE" => "application/xml"),
      env: { "RAW_POST_DATA" => "<ClinicalDocument/>" }

    assert_response :forbidden
  end

  # B3: AuditEvent is the accounting-of-disclosures record, and was unbound.
  test "a patient-bound token cannot read another patient's access trail" do
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      entity_type: "Patient", entity_identifier: "1",
      agent_who_type: "Application", agent_who_identifier: "someone"
    )
    setup_auth(scopes: "patient/*.read", resource_owner_id: 999)

    get "/lakeraven-ehr/AuditEvent", params: { patient: "999" }, headers: @headers

    assert_response :ok
    refute_includes response.body, "Patient/1",
      "the access trail of another patient came back"
  end

  # F2: entity_identifier is a promiscuous column — patient DFNs, amendment
  # ids, encounter iens, class names all share it. Filtering on the bare
  # identifier lets rows from OTHER namespaces leak into a patient's disclosure
  # accounting by numeric collision. The compartment has to key on entity
  # TYPE, not just the value.
  test "an AuditEvent search does not leak rows that collide on the identifier" do
    same_id = "5"
    Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "R", outcome: "0",
      entity_type: "Patient", entity_identifier: same_id,
      agent_who_type: "Application", agent_who_identifier: "legit")
    Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "U", outcome: "0",
      entity_type: "AmendmentRequest", entity_identifier: same_id,
      agent_who_type: "Application", agent_who_identifier: "other")
    Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "R", outcome: "0",
      entity_type: "Encounter", entity_identifier: same_id,
      agent_who_type: "Application", agent_who_identifier: "other")
    setup_auth(scopes: "patient/*.read", resource_owner_id: same_id)

    get "/lakeraven-ehr/AuditEvent", params: { patient: same_id }, headers: @headers

    assert_response :ok
    refute_includes response.body, "AmendmentRequest/#{same_id}",
      "a foreign namespace row leaked by numeric collision"
    refute_includes response.body, "Encounter/#{same_id}"
    assert_includes response.body, "Patient/#{same_id}",
      "the patient's own Patient-typed row must still be returned"
  end

  test "AuditEvent#show does not disclose a colliding foreign row" do
    foreign = Lakeraven::EHR::AuditEvent.create!(event_type: "rest", action: "U", outcome: "0",
      entity_type: "AmendmentRequest", entity_identifier: "7",
      agent_who_type: "Application", agent_who_identifier: "other")
    setup_auth(scopes: "patient/*.read", resource_owner_id: 7)

    get "/lakeraven-ehr/AuditEvent/#{foreign.id}", headers: @headers

    assert_response :not_found
    refute_includes response.body, "AmendmentRequest/7"
  end

  test "an unqualified AuditEvent search is refused to a patient-bound token" do
    setup_auth(scopes: "patient/*.read", resource_owner_id: 999)

    get "/lakeraven-ehr/AuditEvent", headers: @headers
    assert_response :forbidden
  end

  test "an unbound token still reads the facility-wide access trail" do
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      entity_type: "Patient", entity_identifier: "1",
      agent_who_type: "Application", agent_who_identifier: "someone"
    )
    setup_auth(scopes: "system/*.read")

    get "/lakeraven-ehr/AuditEvent", headers: @headers
    assert_response :ok
    assert_includes response.body, "Patient/1"
  end

  test "a read-and-write token can still use the read-as-POST routes" do
    setup_auth(scopes: "system/*.read system/*.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :created
  end

  # -- patient compartment, on searches AND writes ------------------------

  test "a patient-bound token cannot read another patient through the index" do
    setup_auth(scopes: "patient/*.read", resource_owner_id: 999)

    get "/lakeraven-ehr/Patient", headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token cannot read another patient's observations" do
    setup_auth(scopes: "patient/*.read", resource_owner_id: 999)

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token cannot read another patient's conditions" do
    setup_auth(scopes: "patient/*.read", resource_owner_id: 999)

    get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token cannot read another patient's service requests" do
    setup_auth(scopes: "patient/*.read", resource_owner_id: 999)

    get "/lakeraven-ehr/ServiceRequest", params: { patient: "1" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token reads its own compartment" do
    setup_auth(scopes: "patient/*.read", resource_owner_id: 1)

    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    assert_response :ok
  end

  # Binding landed on :index first, which left every POST unbound — the same
  # read through a different verb, and this one returns the whole chart.
  test "a patient-bound token cannot generate a transition of care for another patient" do
    setup_auth(scopes: "patient/*.read patient/*.write", resource_owner_id: 999)

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :forbidden
    refute_includes response.body, "Anderson"
  end

  test "a patient-bound token cannot run an eligibility check for another patient" do
    setup_auth(scopes: "patient/*.read patient/*.write", resource_owner_id: 999)

    post "/lakeraven-ehr/CoverageEligibilityRequest",
      params: { patient_dfn: "1", coverage_type: "medicaid" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token cannot export another patient" do
    setup_auth(scopes: "patient/*.read patient/*.write", resource_owner_id: 999)

    post "/lakeraven-ehr/exports", params: { patient_dfn: "1" }, headers: @headers
    assert_response :forbidden
  end

  test "a patient-bound token may still act within its own compartment" do
    setup_auth(scopes: "patient/*.read patient/*.write", resource_owner_id: 1)

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers
    assert_response :created
  end

  # -- included resource types need the caller's scope --------------------

  test "revinclude does not return Provenance to a Patient-only token" do
    seed_provenance
    setup_auth(scopes: "user/Patient.read")

    get "/lakeraven-ehr/Patient", params: { _revinclude: "Provenance:target" }, headers: @headers
    assert_response :ok
    refute_includes entry_types, "Provenance"
  end

  test "revinclude does return Provenance when the token may read it" do
    seed_provenance
    setup_auth(scopes: "user/Patient.read user/Provenance.read")

    get "/lakeraven-ehr/Patient", params: { _id: "1", _revinclude: "Provenance:target" },
      headers: @headers
    assert_response :ok
    assert_includes entry_types, "Provenance"
  end

  # -- bulk export ownership, on every endpoint that touches one ----------

  test "one client cannot download another client's export files" do
    seed_victim_export
    setup_auth(scopes: "system/*.read system/*.write") # a different client

    get "/lakeraven-ehr/exports/victim-export/files/PatientNdjson", headers: @headers

    assert_response :not_found
    refute_includes response.body, "111-11-1111"
  end

  test "one client cannot delete another client's export" do
    seed_victim_export
    setup_auth(scopes: "system/*.read system/*.write") # a different client

    delete "/lakeraven-ehr/exports/victim-export", headers: @headers

    assert_response :not_found
    assert Lakeraven::EHR::ExportsController.store.key?("victim-export"),
      "the export was removed anyway"
  end

  # An export that is not yours must be indistinguishable from one that does
  # not exist; the refusal used to be an existence oracle (403 vs 404).
  test "a foreign export and a missing export are indistinguishable" do
    seed_victim_export
    setup_auth(scopes: "system/*.read system/*.write")

    delete "/lakeraven-ehr/exports/victim-export", headers: @headers
    foreign = [ response.status, response.body ]

    delete "/lakeraven-ehr/exports/no-such-export-id", headers: @headers
    missing = [ response.status, response.body ]

    assert_equal foreign.first, missing.first
  end

  test "a client can still reach its own export files" do
    seed_victim_export
    setup_auth(scopes: "system/*.read system/*.write")
    Lakeraven::EHR::ExportsController.store["victim-export"].client_id = @application.uid

    get "/lakeraven-ehr/exports/victim-export/files/PatientNdjson", headers: @headers

    assert_response :ok
    assert_includes response.body, "111-11-1111"
  end

  # An export created by a HUMAN carries a DUZ-shaped client_id. This branch
  # has no way to resolve a clinician identity (that arrives with #486), so
  # the ownership question is unanswerable — and an unanswerable authorization
  # question is a refusal, not a fallback to the shared application.
  test "an export owned by a clinician is refused while no clinician identity is resolvable" do
    seed_victim_export(owner: "304")
    setup_auth(scopes: "system/*.read system/*.write")

    get "/lakeraven-ehr/exports/victim-export/files/PatientNdjson", headers: @headers

    assert_response :not_found
    refute_includes response.body, "111-11-1111"
  end

  # -- the C-CDA author is an attestation, not a request parameter --------

  test "the C-CDA author cannot be forged through a request parameter" do
    setup_auth(scopes: "system/*.read system/*.write")

    post "/lakeraven-ehr/transitions_of_care",
      params: { patient_dfn: "1", author_name: "FORGED,AUTHOR", author_npi: "9999999999" },
      headers: @headers

    assert_response :created
    refute_includes response.body, "FORGED,AUTHOR"
    refute_includes response.body, "9999999999"
  end

  # The degraded author has to actually REACH the artifact. It previously did
  # not: the generator read only :name and :institution, dropped :device, :npi
  # and :duz, and emitted an assignedAuthor with neither an assignedPerson nor
  # an assignedAuthoringDevice — C-CDA-invalid, while still asserting a
  # hardcoded extension="provider". Silent, not honest.
  test "a C-CDA with no human author names the authoring device instead" do
    setup_auth(scopes: "system/*.read system/*.write")

    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers

    assert_response :created
    assert_includes response.body, "assignedAuthoringDevice"
    refute_includes response.body, "assignedPerson"
    refute_includes response.body, 'extension="provider"',
      "the document asserted a provider id for a document no provider authored"
  end

  test "the C-CDA author block is valid whichever branch it takes" do
    setup_auth(scopes: "system/*.read system/*.write")
    post "/lakeraven-ehr/transitions_of_care", params: { patient_dfn: "1" }, headers: @headers

    author = response.body[%r{<author>.*?</author>}m]
    refute_nil author
    assert author.include?("assignedPerson") || author.include?("assignedAuthoringDevice"),
      "assignedAuthor with neither assignedPerson nor assignedAuthoringDevice is invalid"
  end

  private

  def setup_auth(scopes:, resource_owner_id: nil)
    @application = Doorkeeper::Application.create!(
      name: "client-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @application, scopes: scopes, expires_in: 3600,
      resource_owner_id: resource_owner_id
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def entry_types
    JSON.parse(response.body).fetch("entry", []).map { |e| e.dig("resource", "resourceType") }
  end

  def seed_provenance
    Lakeraven::EHR::ProvenanceStore.instance.add(
      Lakeraven::EHR::Provenance.new(
        target_type: "Patient", target_id: "rpms-1", activity: "CREATE",
        agent_who_id: "304", agent_who_type: "Practitioner", recorded: Time.current
      )
    )
  end

  # An export belonging to someone else, with real PHI in the payload.
  # Ownership is the subject here, not export generation.
  def seed_victim_export(owner: "another-client-uid")
    export = Lakeraven::EHR::BulkExport.new(
      id: "victim-export", export_type: "patient", status: "completed",
      request_url: "https://example.test/exports",
      output_format: "application/fhir+ndjson", client_id: owner
    )
    export.output_files = [
      { "file_name" => "PatientNdjson", "type" => "Patient", "count" => 1,
        "content" => '{"resourceType":"Patient","ssn":"111-11-1111","name":"Anderson,Alice"}' }
    ]
    Lakeraven::EHR::ExportsController.store["victim-export"] = export
  end
end
