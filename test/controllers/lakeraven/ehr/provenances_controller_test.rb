# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # Provenance endpoints against the seeded measurement read graph
    # (test_helper: patient 1's measurements 5001-5007 on visit 9001,
    # service category "A"). No hidden patient parameter anywhere — the
    # by-IEN read (rpms-rpc Measurement.find) supplies the patient itself.
    class ProvenancesControllerTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup { setup_smart_auth }
      teardown { teardown_smart_auth }

      test "show resolves a measurement-IEN-backed id without a patient param" do
        get "/lakeraven-ehr/Provenance/prov-5002", headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Provenance", body["resourceType"]
        assert_equal "prov-5002", body["id"]
        assert_equal "Observation/5002", body.dig("target", 0, "reference")
      end

      test "target search resolves without a patient param" do
        get "/lakeraven-ehr/Provenance", params: { target: "Observation/5002" }, headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "Bundle", body["resourceType"]
        assert_equal 1, body["entry"].length
        assert_equal "prov-5002", body.dig("entry", 0, "resource", "id")
      end

      test "show returns 404 for an unknown measurement" do
        get "/lakeraven-ehr/Provenance/prov-999999", headers: @headers

        assert_response :not_found
        assert_equal "OperationOutcome", JSON.parse(response.body)["resourceType"]
      end

      test "patient search lists provenance for the patient's measurements" do
        get "/lakeraven-ehr/Provenance", params: { patient: "1" }, headers: @headers

        assert_response :ok
        body = JSON.parse(response.body)
        assert_operator body["entry"].length, :>, 0
        body["entry"].each do |entry|
          resource = entry["resource"]
          assert_equal "Provenance", resource["resourceType"]
          agent_type = resource.dig("agent", 0, "type")
          assert agent_type.nil? || agent_type.is_a?(Hash),
            "agent.type must be a single CodeableConcept (0..1)"
        end
      end

      test "search without patient or target returns 400" do
        get "/lakeraven-ehr/Provenance", headers: @headers

        assert_response :bad_request
      end
    end
  end
end
