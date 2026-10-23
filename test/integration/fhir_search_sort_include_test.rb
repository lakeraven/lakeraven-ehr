# frozen_string_literal: true

require "test_helper"

# FHIR search _sort and _include (#649): sorting on the parameters each
# resource declares, forward-reference includes that pass the same scope
# checks as direct reads, and a 400 naming any value that is not declared.
class FhirSearchSortIncludeTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  setup do
    setup_smart_auth
  end

  teardown do
    teardown_smart_auth
  end

  # Baseline patients: 1 Anderson,Alice F 1980; 2 MOUSE,MICKEY M 2010;
  # 3 DOE,JANE F 1990.

  # -- _sort -------------------------------------------------------------------

  test "_sort sorts ascending, and - sorts descending" do
    get "/lakeraven-ehr/Patient", params: { _sort: "birthdate" }, headers: @headers
    assert_response :ok
    assert_equal %w[1 3 2], match_ids

    get "/lakeraven-ehr/Patient", params: { _sort: "-birthdate" }, headers: @headers
    assert_equal %w[2 3 1], match_ids
  end

  test "_sort by name compares case-folded family then given" do
    get "/lakeraven-ehr/Patient", params: { _sort: "name" }, headers: @headers

    assert_equal %w[1 3 2], match_ids, "Anderson, DOE, MOUSE"
  end

  test "_sort by name ignores case" do
    seed_patients([
      { dfn: 1, name: "BAKER,BOB", sex: "M", dob: Date.new(1980, 1, 1) },
      { dfn: 2, name: "adams,amy", sex: "F", dob: Date.new(1980, 1, 1) }
    ])

    get "/lakeraven-ehr/Patient", params: { _sort: "name" }, headers: @headers

    assert_equal %w[2 1], match_ids, "adams before BAKER"
  end

  test "a second _sort key breaks ties in the first" do
    get "/lakeraven-ehr/Patient", params: { _sort: "gender,-birthdate" }, headers: @headers

    assert_equal %w[3 1 2], match_ids, "females newest first, then the male"
  end

  test "_sort=_id compares numeric ids as numbers" do
    seed_patient_list(%w[1 2 3 10])

    get "/lakeraven-ehr/Patient", params: { _sort: "-_id" }, headers: @headers

    assert_equal %w[10 3 2 1], match_ids
  end

  test "the match set is sorted before it is paged, and the links keep the sort" do
    get "/lakeraven-ehr/Patient", params: { _sort: "-birthdate", _count: "1" }, headers: @headers
    assert_equal %w[2], match_ids
    assert_equal "-birthdate", query_of(link("next"))["_sort"]

    follow link("next")
    assert_equal %w[3], match_ids
    follow link("next")
    assert_equal %w[1], match_ids
  end

  test "dates sort chronologically and a match with no date sorts last both ways" do
    RpmsRpc.client.seed_keyed_collection(:vitals, "1", [
      { measurement_ien: 3001, type: "P", value: "70", units: "/min", recorded_date: Time.new(2025, 3, 1, 9, 0, 0) },
      { measurement_ien: 3002, type: "P", value: "71", units: "/min", recorded_date: nil },
      { measurement_ien: 3003, type: "P", value: "72", units: "/min", recorded_date: Time.new(2024, 12, 31, 23, 0, 0) },
      { measurement_ien: 3004, type: "P", value: "73", units: "/min", recorded_date: Time.new(2025, 1, 1, 8, 0, 0) }
    ])

    get "/lakeraven-ehr/Observation", params: { patient: "1", _sort: "date" }, headers: @headers
    assert_response :ok
    assert_equal [ 72, 73, 70, 71 ], pulse_values

    get "/lakeraven-ehr/Observation", params: { patient: "1", _sort: "-date" }, headers: @headers
    assert_equal [ 70, 73, 72, 71 ], pulse_values

    # Observation renders through render_bundle_egress, the shared path:
    # it too sorts the whole match set before cutting the page.
    get "/lakeraven-ehr/Observation", params: { patient: "1", _sort: "-date", _count: "2" }, headers: @headers
    assert_equal [ 70, 73 ], pulse_values
    follow link("next")
    assert_equal [ 72, 71 ], pulse_values
  end

  test "ties keep the backend's order" do
    get "/lakeraven-ehr/Observation", params: { patient: "1" }, headers: @headers
    unsorted = match_ids

    # Every baseline vital shares one timestamp.
    get "/lakeraven-ehr/Observation", params: { patient: "1", _sort: "date" }, headers: @headers
    assert_equal unsorted, match_ids
    get "/lakeraven-ehr/Observation", params: { patient: "1", _sort: "-date" }, headers: @headers
    assert_equal unsorted, match_ids
  end

  test "AuditEvent sorts in the query: -date is newest first" do
    3.times { |i| audit_row!(i) }

    get "/lakeraven-ehr/AuditEvent", params: { _sort: "-date", _count: "100" }, headers: @headers
    assert_response :ok
    recorded = match_resources.map { |r| r["recorded"] }
    assert_operator recorded.length, :>=, 3
    assert_equal recorded.sort.reverse, recorded

    get "/lakeraven-ehr/AuditEvent", params: { _sort: "-_id", _count: "100" }, headers: @headers
    ids = match_ids.map(&:to_i)
    assert_equal ids.sort.reverse, ids
  end

  {
    "foo" => "foo", "-foo" => "-foo", "birthdate,foo" => "foo",
    "date" => "date", "" => "", "name," => ""
  }.each do |value, named|
    test "Patient _sort=#{value.inspect} is refused with a 400 naming #{named.inspect}" do
      get "/lakeraven-ehr/Patient", params: { _sort: value }, headers: @headers

      assert_refused_naming("_sort", named)
    end
  end

  test "a resource that declares no sort refuses every _sort" do
    get "/lakeraven-ehr/Encounter", params: { patient: "1", _sort: "_id" }, headers: @headers

    assert_refused_naming("_sort", "_id")
    assert_includes outcome_diagnostics, "Encounter supports none"
  end

  # -- _include ----------------------------------------------------------------

  test "_include=MedicationRequest:patient appends the patient once, outside total" do
    seed_two_medications

    get "/lakeraven-ehr/MedicationRequest",
      params: { patient: "1", _include: "MedicationRequest:patient" }, headers: @headers

    assert_response :ok
    assert_equal 2, bundle["total"]
    assert_equal 2, match_resources.length
    included = entries_with_mode("include").map { |e| e["resource"] }
    assert_equal [ [ "Patient", "1" ] ], included.map { |r| [ r["resourceType"], r["id"] ] }
    assert_equal "Anderson", included.first.dig("name", 0, "family")
  end

  test "repeated _include values are each followed, and the links repeat them" do
    RpmsRpc.client.seed_keyed_collection(:immunization_list, "1^I", [
      { record_type: "I", ien: 1, vaccine_display: "COVID-19 Vaccine",
        occurrence_datetime: DateTime.new(2026, 1, 15, 9, 0, 0), performer: "101~MARTINEZ,SARAH" }
    ])

    get "/lakeraven-ehr/Immunization?patient=1&_include=Immunization:patient&_include=Immunization:performer",
      headers: @headers

    assert_response :ok
    included = entries_with_mode("include").map { |e| "#{e.dig('resource', 'resourceType')}/#{e.dig('resource', 'id')}" }
    assert_equal %w[Patient/1 Practitioner/101], included.sort
    assert_equal %w[Immunization:patient Immunization:performer],
      Rack::Utils.parse_query(URI(link("self")).query)["_include"]
  end

  test "an included type the token cannot read is withheld, and an outcome entry says so" do
    seed_two_medications
    setup_smart_auth(scopes: "system/MedicationRequest.read")

    get "/lakeraven-ehr/MedicationRequest",
      params: { patient: "1", _include: "MedicationRequest:patient" }, headers: @headers

    assert_response :ok
    assert_empty entries_with_mode("include")
    outcome = entries_with_mode("outcome").map { |e| e["resource"] }
    assert_equal [ "OperationOutcome" ], outcome.map { |r| r["resourceType"] }
    assert_includes outcome.first.dig("issue", 0, "diagnostics"), "Patient"
    assert_equal 2, match_resources.length
  end

  test "a patient-bound token includes its own patient" do
    seed_two_medications
    patient_token!("patient/MedicationRequest.read patient/Patient.read", dfn: "1")

    get "/lakeraven-ehr/MedicationRequest",
      params: { patient: "1", _include: "MedicationRequest:patient" }, headers: @headers

    assert_response :ok
    assert_equal [ "1" ], entries_with_mode("include").map { |e| e.dig("resource", "id") }
  end

  test "included resources pass through the Part 2 egress seam with the matches" do
    seed_two_medications
    seen = nil
    with_egress_filter(->(payload) {
      seen = payload
      bundle = payload.deep_dup.deep_stringify_keys
      bundle["entry"].reject! { |e| e.dig("resource", "resourceType") == "Patient" }
      bundle
    }) do
      get "/lakeraven-ehr/MedicationRequest",
        params: { patient: "1", _include: "MedicationRequest:patient" }, headers: @headers
    end

    assert_response :ok
    seen_types = seen[:entry].map { |e| e[:resource][:resourceType] }
    assert_includes seen_types, "Patient", "the filter must see the included Patient"
    refute_includes bundle["entry"].map { |e| e.dig("resource", "resourceType") }, "Patient",
      "the response is what the filter returned"
  end

  test "a backend failure reading an included resource fails the search" do
    seed_two_medications
    failing = Class.new do
      def self.find(_dfn) = raise(RpmsRpc::Client::ConnectionError, "broker down")
    end
    with_patient_repository(failing) do
      assert_raises(RpmsRpc::Client::ConnectionError) do
        get "/lakeraven-ehr/MedicationRequest",
          params: { patient: "1", _include: "MedicationRequest:patient" }, headers: @headers
      end
    end
  end

  {
    "MedicationRequest:requester" => "/lakeraven-ehr/MedicationRequest?patient=1",
    "Patient:patient" => "/lakeraven-ehr/MedicationRequest?patient=1",
    "*" => "/lakeraven-ehr/MedicationRequest?patient=1",
    "Patient:general-practitioner" => "/lakeraven-ehr/Patient?"
  }.each do |value, path|
    test "_include=#{value} on #{URI(path).path} is refused with a 400 naming it" do
      get "#{path}&_include=#{CGI.escape(value)}", headers: @headers

      assert_refused_naming("_include", value)
    end
  end

  test "_include:iterate is refused rather than read as a plain _include" do
    get "/lakeraven-ehr/MedicationRequest?patient=1&_include:iterate=MedicationRequest:patient", headers: @headers

    assert_refused_naming("_include:iterate", "MedicationRequest:patient")
  end

  # -- Declaration ---------------------------------------------------------------

  test "every declared sort and include is accepted by the resource it is declared on" do
    caps = Lakeraven::EHR::FHIR::SearchCapabilities
    caps::RESOURCES.each_key do |type|
      caps.sorts_for(type).each_key do |name|
        get "/lakeraven-ehr/#{type}", params: { patient: "1", _sort: "-#{name}" }, headers: @headers
        assert_response :ok, "#{type} _sort=-#{name}"
      end
      caps.includes_for(type).each_key do |value|
        get "/lakeraven-ehr/#{type}", params: { patient: "1", _include: value }, headers: @headers
        assert_response :ok, "#{type} _include=#{value}"
      end
    end
  end

  test "the CapabilityStatement fragment lists what is enforced" do
    caps = Lakeraven::EHR::FHIR::SearchCapabilities
    medication = caps.resource_capabilities("MedicationRequest")

    assert_equal %w[MedicationRequest:patient MedicationRequest:subject], medication[:searchInclude]
    assert_equal %w[status _sort], medication[:searchParam].map { |param| param[:name] }
    sort = medication[:searchParam].find { |param| param[:name] == "_sort" }
    assert_includes sort[:documentation], "status"
    assert_equal({}, caps.resource_capabilities("Encounter"))
  end

  private

  def bundle
    JSON.parse(response.body)
  end

  def entries_with_mode(mode)
    bundle.fetch("entry", []).select { |e| e.dig("search", "mode") == mode }
  end

  def match_resources
    entries_with_mode("match").map { |e| e["resource"] }
  end

  def match_ids
    match_resources.map { |r| r["id"] }
  end

  def pulse_values
    match_resources.map { |r| r.dig("valueQuantity", "value").to_i }
  end

  def link(relation)
    bundle.fetch("link", []).find { |l| l["relation"] == relation }&.fetch("url")
  end

  def query_of(url)
    Rack::Utils.parse_query(URI(url).query)
  end

  def follow(url)
    uri = URI(url)
    get "#{uri.path}?#{uri.query}", headers: @headers
  end

  def outcome_diagnostics
    bundle.dig("issue", 0, "diagnostics").to_s
  end

  def assert_refused_naming(name, value)
    assert_response :bad_request
    assert_equal "OperationOutcome", bundle["resourceType"]
    assert_equal "not-supported", bundle.dig("issue", 0, "code")
    assert_includes outcome_diagnostics, name
    assert_includes outcome_diagnostics, value.inspect
  end

  def seed_patient_list(dfns)
    seed_patients(dfns.map { |dfn| { dfn: dfn.to_i, name: "PATIENT,#{dfn}", sex: "F", dob: Date.new(1980, 1, 1) } })
  end

  # ORWPT LIST ALL rows carry the DFN and name only; the search reads each
  # match with ORWPT SELECT and ORWPT ID INFO (rpms-rpc #352), so each
  # patient is seeded on all three.
  def seed_patients(patients)
    RpmsRpc.client.seed_collection(:patient_list, patients.map { |p| p.slice(:dfn, :name) })
    patients.each do |p|
      RpmsRpc.client.seed(:patient_select, p[:dfn].to_s, p.slice(:name, :sex, :dob))
      RpmsRpc.client.seed(:patient_id_info, p[:dfn].to_s, p.slice(:name, :sex, :dob))
    end
  end

  def seed_two_medications
    RpmsRpc.client.seed_text(:medication_active, "1", <<~WIRE)
      ~OP^1R;O^LISINOPRIL 10MG TAB^^3271231^3^^^120001^ACTIVE
      \\ Sig: TAKE 1 TABLET BY MOUTH DAILY
      ~OP^2R;O^METFORMIN 500MG TAB^^3271231^1^^^120002^ACTIVE
      \\ Sig: TAKE 1 TABLET BY MOUTH TWICE A DAY
    WIRE
  end

  def patient_token!(scopes, dfn:)
    app = Doorkeeper::Application.create!(
      name: "patient-app", redirect_uri: "https://example.test/cb", scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: app, scopes: scopes, expires_in: 3600, resource_owner_id: dfn
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def audit_row!(index)
    Lakeraven::EHR::AuditEvent.create!(
      event_type: "rest", action: "R", outcome: "0",
      entity_type: "Patient", entity_identifier: (index + 1).to_s
    )
  end

  def with_egress_filter(transform)
    filter = Lakeraven::EHR::Part2EgressFilter.singleton_class
    original = filter.instance_method(:call)
    filter.define_method(:call) { |payload| transform.call(payload) }
    yield
  ensure
    filter.define_method(:call, original)
  end

  def with_patient_repository(replacement)
    repository = Lakeraven::EHR::PatientRepository.singleton_class
    original = repository.instance_method(:find)
    repository.define_method(:find) { |dfn| replacement.find(dfn) }
    yield
  ensure
    repository.define_method(:find, original)
  end
end
