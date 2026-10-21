# frozen_string_literal: true

require "test_helper"

# FHIR R4: Bundle.total is the number of resources matching the search, not
# entries added by _include / _revinclude. PatientsController#index currently
# sets total to entries.length, so revinclude rows inflate total.
class PatientSearchTotalTest < ActionDispatch::IntegrationTest
  setup do
    Lakeraven::EHR::ProvenanceStore.reset_instance!
  end

  test "Patient search total excludes Provenance revinclude rows for a single match" do
    seed_provenance_for_dfn("1")
    setup_auth(scopes: "system/Patient.read system/Provenance.read")

    get "/lakeraven-ehr/Patient",
      params: { _id: "1", _revinclude: "Provenance:target" },
      headers: @headers

    assert_response :ok
    assert_provenance_revincluded
    assert_bundle_total_equals_match_count_only
    assert_equal 1, match_entry_count
  end

  test "Patient search total excludes Provenance revinclude rows for multiple matches" do
    seed_provenance_for_dfn("1")
    seed_provenance_for_dfn("2")
    seed_provenance_for_dfn("3")
    setup_auth(scopes: "system/Patient.read system/Provenance.read")

    get "/lakeraven-ehr/Patient",
      params: { _revinclude: "Provenance:target" },
      headers: @headers

    assert_response :ok
    assert_provenance_revincluded
    assert_operator match_entry_count, :>, 1,
      "expected a multi-patient search (match entries > 1)"
    assert_bundle_total_equals_match_count_only
  end

  test "Patient search total equals match count when Provenance.read is absent" do
    seed_provenance_for_dfn("1")
    setup_auth(scopes: "system/Patient.read")

    get "/lakeraven-ehr/Patient",
      params: { _id: "1", _revinclude: "Provenance:target" },
      headers: @headers

    assert_response :ok
    refute_includes entry_resource_types, "Provenance",
      "without Provenance.read, revinclude must not return Provenance"
    assert_empty include_provenance_entries
    assert_bundle_total_equals_match_count
    assert_equal 1, match_entry_count
  end

  private

  def setup_auth(scopes:)
    @application = Doorkeeper::Application.create!(
      name: "client-#{SecureRandom.hex(4)}", redirect_uri: "https://example.test/cb",
      scopes: scopes, confidential: true
    )
    token = Doorkeeper::AccessToken.create!(
      application: @application, scopes: scopes, expires_in: 3600
    )
    @headers = { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }
  end

  def seed_provenance_for_dfn(dfn)
    Lakeraven::EHR::ProvenanceStore.instance.add(
      Lakeraven::EHR::Provenance.new(
        target_type: "Patient", target_id: "rpms-#{dfn}", activity: "CREATE",
        agent_who_id: "9001", agent_who_type: "Practitioner", recorded: Time.current
      )
    )
  end

  def parsed_bundle
    JSON.parse(response.body)
  end

  def bundle_entries
    parsed_bundle.fetch("entry", [])
  end

  def entry_resource_types
    bundle_entries.map { |e| e.dig("resource", "resourceType") }
  end

  def match_entry_count
    bundle_entries.count { |e| e.dig("search", "mode") == "match" }
  end

  def include_provenance_entries
    bundle_entries.select do |e|
      e.dig("resource", "resourceType") == "Provenance" &&
        e.dig("search", "mode") == "include"
    end
  end

  def assert_provenance_revincluded
    assert include_provenance_entries.any?,
      "expected at least one Provenance entry with search.mode include"
  end

  def assert_bundle_total_equals_match_count
    bundle = parsed_bundle
    matches = match_entry_count

    assert_equal matches, bundle["total"],
      "Bundle.total must count match-mode entries only (got total=#{bundle['total']}, matches=#{matches})"
  end

  def assert_bundle_total_equals_match_count_only
    assert_bundle_total_equals_match_count
    bundle = parsed_bundle
    assert_operator bundle["total"], :<, bundle_entries.size,
      "total must be less than entry count when revinclude rows are present"
  end
end
