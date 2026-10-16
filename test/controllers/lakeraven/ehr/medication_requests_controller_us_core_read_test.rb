# frozen_string_literal: true

require "test_helper"
require_relative "../../../dummy/lib/lakeraven_demo_seeds"

module Lakeraven
  module EHR
    class MedicationRequestsControllerUsCoreReadTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      setup do
        @original_client = RpmsRpc.configuration.client
        RpmsRpc.mock! { |m| LakeravenDemoSeeds.seed(m) }
        setup_smart_auth
      end

      teardown do
        teardown_smart_auth
        RpmsRpc.configure { |c| c.client = @original_client }
      end

      test "search entries serialize medication list rows as FHIR MedicationRequest resources" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers

        assert_response :ok
        resources = JSON.parse(response.body)["entry"].map { |e| e["resource"] }
        refute_empty resources

        lisinopril = resources.find { |r| r.dig("medicationCodeableConcept", "text") == "Lisinopril 10mg" }
        assert lisinopril, "expected seeded Lisinopril order in the bundle"

        assert_equal "MedicationRequest", lisinopril["resourceType"]
        assert_equal "1", lisinopril["id"]
        assert_equal "active", lisinopril["status"]
        assert_equal "order", lisinopril["intent"]
        assert_equal "Patient/1", lisinopril.dig("subject", "reference")
        assert_equal "Lisinopril 10mg", lisinopril.dig("medicationCodeableConcept", "text")
      end

      test "search entries omit raw RPMS medication field names" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers

        assert_response :ok
        JSON.parse(response.body)["entry"].each do |entry|
          resource = entry["resource"]
          refute resource.key?("drug_name"), "gateway drug_name must not appear on the FHIR resource"
          refute resource.key?("sig"), "gateway sig must not appear on the FHIR resource"
        end
      end

      test "search entries use medicationCodeableConcept text without RxNorm when RPMS has no code" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers

        assert_response :ok
        JSON.parse(response.body)["entry"].each do |entry|
          concept = entry.dig("resource", "medicationCodeableConcept")
          assert concept.is_a?(Hash), "expected medicationCodeableConcept on the FHIR resource"
          assert concept["text"].present?
          assert_nil concept["coding"],
                     "RxNorm coding must be absent when the gateway row has no medication code"
        end
      end

      test "search entries omit authoredOn and requester when RPMS does not supply them" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers

        assert_response :ok
        JSON.parse(response.body)["entry"].each do |entry|
          resource = entry["resource"]
          assert resource["intent"].present?, "intent is required on MedicationRequest"
          assert_nil resource["authoredOn"], "authoredOn must be absent, not invented"
          assert_nil resource["requester"], "requester must be absent, not invented"
        end
      end
    end
  end
end
