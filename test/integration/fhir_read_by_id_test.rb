# frozen_string_literal: true

require "test_helper"

# Inferno (g)(10) reads every record a search returned (#845): the read serves
# what the search served, under the same id. The id names the patient, so a
# read binds the compartment before anything reaches RPMS, finds the record in
# that patient's list only, and audits against that patient.
class FhirReadByIdTest < ActionDispatch::IntegrationTest
  include BrokerStubbing
  include SmartAuthTestHelper

  ENGINE = "/lakeraven-ehr"

  SEEDS = {
    "Condition" => -> { RpmsRpc.client.seed_keyed_collection(:problem_list, "1", [ { ien: 41, status: "A", icd_code: "E11.9", description: "Diabetes" } ]) },
    "AllergyIntolerance" => -> { RpmsRpc.client.seed_keyed_collection(:allergy_list, "1", [ { ien: 41, allergen: "Penicillin" } ]) },
    "MedicationRequest" => -> { RpmsRpc.client.seed_text(:medication_active, "1", "~OP^41R;O^METFORMIN 500MG TAB^^3271231^1^^^120041^ACTIVE\n") },
    "Observation" => -> { },
    "Immunization" => -> { RpmsRpc.client.seed_keyed_collection(:immunization_list, "1^I", [ { record_type: "I", ien: 41, vaccine_display: "Influenza" } ]) },
    "Procedure" => -> { RpmsRpc.client.seed_keyed_collection(:procedure_list, "1", [ { ien: 41, name: "Office visit", date: Date.new(2026, 3, 10) } ]) },
    "ServiceRequest" => -> { RpmsRpc.client.seed_keyed_collection(:referral_search, "1", [ { ien: 41, status: "A", purpose: "Cardiology" } ]) }
  }.freeze

  setup { setup_smart_auth(scopes: "system/*.read") }
  teardown { teardown_smart_auth }

  def first_match(type, headers: @headers)
    get "#{ENGINE}/#{type}", params: { patient: "1" }, headers: headers
    assert_response :ok, "#{type} search: #{response.body}"
    JSON.parse(response.body)["entry"].find { |entry| entry.dig("search", "mode") == "match" }.fetch("resource")
  end

  SEEDS.each do |type, seed|
    test "#{type}: a record a search returned reads back the same" do
      instance_exec(&seed)
      found = first_match(type)
      assert_match(/\A1-./, found["id"])

      get "#{ENGINE}/#{type}/#{found['id']}", headers: @headers

      assert_response :ok, response.body
      assert_equal "application/fhir+json", response.media_type
      assert_equal found, JSON.parse(response.body)
    end

    test "#{type}: a record that is not in the named patient's list is a 404" do
      instance_exec(&seed)
      found = first_match(type)
      record = found["id"].delete_prefix("1-")

      get "#{ENGINE}/#{type}/3-#{record}", headers: @headers

      assert_response :not_found
      assert_equal "not-found", JSON.parse(response.body).dig("issue", 0, "code")
    end

    test "#{type}: a token bound to another patient is refused before RPMS is asked" do
      instance_exec(&seed)
      id = first_match(type)["id"]
      token = Doorkeeper::AccessToken.create!(
        application: @oauth_app, scopes: "patient/#{type}.read", expires_in: 3600, resource_owner_id: 999
      )
      before = RpmsRpc.client.received_calls.length

      get "#{ENGINE}/#{type}/#{id}", headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }

      assert_response :forbidden
      assert_equal before, RpmsRpc.client.received_calls.length
    end

    test "#{type}: a token bound to the record's patient reads it" do
      instance_exec(&seed)
      id = first_match(type)["id"]
      token = Doorkeeper::AccessToken.create!(
        application: @oauth_app, scopes: "patient/#{type}.read", expires_in: 3600, resource_owner_id: 1
      )

      get "#{ENGINE}/#{type}/#{id}", headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }

      assert_response :ok
    end
  end

  test "an id that names no patient is a 404, not a refusal, and asks RPMS nothing" do
    %w[99999 abc 0-1 -1].each do |id|
      before = RpmsRpc.client.received_calls.length

      get "#{ENGINE}/Condition/#{id}", headers: @headers

      assert_response :not_found, id
      assert_equal before, RpmsRpc.client.received_calls.length, id
    end
  end

  # SMART v2: `r` reads by id, `s` searches.
  test "a read needs a read scope, not a search scope" do
    SEEDS["Condition"].call
    token = Doorkeeper::AccessToken.create!(application: @oauth_app, scopes: "system/Condition.s", expires_in: 3600)

    get "#{ENGINE}/Condition/1-41", headers: { "Authorization" => "Bearer #{token.plaintext_token || token.token}" }

    assert_response :forbidden
  end

  test "a read is on the patient's accounting of disclosures" do
    SEEDS["Condition"].call

    get "#{ENGINE}/Condition/1-41", headers: @headers

    assert_response :ok
    audit = Lakeraven::EHR::AuditEvent.order(:id).last
    assert_equal [ "Patient", "1" ], [ audit.entity_type, audit.entity_identifier ]
  end

  test "a read goes through the Part 2 egress seam" do
    SEEDS["Condition"].call
    calls = []
    original = Lakeraven::EHR::Part2EgressFilter.method(:call)
    Lakeraven::EHR::Part2EgressFilter.define_singleton_method(:call) { |payload| calls << payload; nil }

    begin
      get "#{ENGINE}/Condition/1-41", headers: @headers
    ensure
      Lakeraven::EHR::Part2EgressFilter.define_singleton_method(:call, original)
    end

    assert_response :service_unavailable
    assert_equal [ "1-41" ], calls.map { |payload| payload[:id] }
  end
end
