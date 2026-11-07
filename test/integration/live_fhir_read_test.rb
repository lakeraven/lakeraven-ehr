# frozen_string_literal: true

require "test_helper"

# Live (#845, #848): every record a search finds on the demo build reads back
# by its id, from RPMS, unchanged. DFN 2 and 4 are the panel patients with a
# chart.
# The demo build has no MedicationRequest or ServiceRequest for them, so a
# type that finds nothing fails here rather than proving nothing: see EMPTY.
#
#   LIVE_RPMS=1 VISTA_BROKER=cia VISTA_RPC_HOST=127.0.0.1 VISTA_RPC_PORT=9153 \
#   LIVE_RPMS_ACCESS=PMD123 LIVE_RPMS_VERIFY='PMD123!!' \
#   bin/rails test test/integration/live_fhir_read_test.rb
class LiveFhirReadTest < ActionDispatch::IntegrationTest
  include SmartAuthTestHelper

  ENGINE = "/lakeraven-ehr"
  DFN = "4"
  SERVED = %w[Condition AllergyIntolerance Observation Immunization Procedure Encounter].freeze
  EMPTY = %w[MedicationRequest ServiceRequest].freeze

  setup do
    skip "live: set LIVE_RPMS=1 against a local container" unless defined?(LIVE_RPMS) && LIVE_RPMS
    setup_smart_auth(scopes: "system/*.read")
  end

  teardown { teardown_smart_auth if defined?(LIVE_RPMS) && LIVE_RPMS }

  def matches(type, dfn)
    get "#{ENGINE}/#{type}", params: { patient: dfn, _count: "100" }, headers: @headers
    assert_response :ok, "#{type}: #{response.body}"
    Array(JSON.parse(response.body)["entry"]).map { |entry| entry.fetch("resource") }
  end

  SERVED.each do |type|
    test "#{type}: every record the demo patient's search finds reads back" do
      found = matches(type, DFN)
      refute_empty found, "the demo build's patient #{DFN} has a #{type}"

      found.each do |resource|
        get "#{ENGINE}/#{type}/#{resource.fetch('id')}", headers: @headers

        assert_response :ok, response.body
        assert_equal resource, JSON.parse(response.body)
      end
    end

    test "#{type}: a record of patient #{DFN} is not found under patient 2" do
      record = matches(type, DFN).first.fetch("id").delete_prefix("#{DFN}-")

      get "#{ENGINE}/#{type}/2-#{record}", headers: @headers

      assert_response :not_found
    end
  end

  test "a visit is a US Core Encounter, and its references resolve" do
    encounter = matches("Encounter", DFN).first

    assert_equal "finished", encounter["status"]
    assert_equal "AMB", encounter.dig("class", "code")
    assert_equal "AMBULATORY", encounter.dig("type", 0, "text")
    assert encounter.dig("period", "start")
    [ encounter.dig("subject", "reference"), encounter.dig("location", 0, "location", "reference"),
      encounter.dig("participant", 0, "individual", "reference") ].each do |reference|
      get "#{ENGINE}/#{reference}", headers: @headers
      assert_response :ok, "#{reference}: #{response.body}"
    end
  end

  test "a visit diagnosis is an encounter-diagnosis that names a visit of the patient" do
    visits = matches("Encounter", DFN).map { |encounter| encounter["id"] }
    diagnoses = matches("Condition", DFN).select { |condition| condition.dig("category", 0, "coding", 0, "code") == "encounter-diagnosis" }

    refute_empty diagnoses
    assert diagnoses.any? { |diagnosis| diagnosis["encounter"] }, "the demo patient's clinic visits carry diagnoses"
    diagnoses.each do |diagnosis|
      reference = diagnosis.dig("encounter", "reference")
      assert_includes visits, reference.delete_prefix("Encounter/") if reference
      assert_match(/\A[A-Z]\d/, diagnosis.dig("code", "coding", 0, "code"))
      assert_match(/\A\d{4}-\d\d-\d\d\z/, diagnosis["recordedDate"])
    end
  end

  test "an Encounter is found by _id alone" do
    id = matches("Encounter", DFN).first.fetch("id")

    get "#{ENGINE}/Encounter", params: { _id: id }, headers: @headers

    assert_response :ok
    assert_equal [ id ], JSON.parse(response.body).fetch("entry").map { |entry| entry.dig("resource", "id") }
  end

  test "a Location search finds a location by the start of its name, in any case" do
    get "#{ENGINE}/Location", params: { name: "demo prim" }, headers: @headers

    assert_response :ok
    names = JSON.parse(response.body).fetch("entry").map { |entry| entry.dig("resource", "name") }
    assert_includes names, "DEMO PRIMARY CARE"
  end

  EMPTY.each do |type|
    test "#{type}: a search that finds nothing leaves nothing to read" do
      assert_empty matches(type, DFN)

      get "#{ENGINE}/#{type}/#{DFN}-1", headers: @headers

      assert_response :not_found
    end
  end
end
