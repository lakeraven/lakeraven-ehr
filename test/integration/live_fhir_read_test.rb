# frozen_string_literal: true

require "test_helper"

# Live (#845): every record a search finds on the demo build reads back by its
# id, from RPMS, unchanged. DFN 2 and 4 are the panel patients with a chart.
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
  SERVED = %w[Condition AllergyIntolerance Observation Immunization Procedure].freeze
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

  EMPTY.each do |type|
    test "#{type}: a search that finds nothing leaves nothing to read" do
      assert_empty matches(type, DFN)

      get "#{ENGINE}/#{type}/#{DFN}-1", headers: @headers

      assert_response :not_found
    end
  end
end
