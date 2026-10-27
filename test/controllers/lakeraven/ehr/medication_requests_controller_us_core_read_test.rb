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

      test "search entries serialize active medication rows as FHIR MedicationRequest resources" do
        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers

        assert_response :ok
        resources = JSON.parse(response.body)["entry"].map { |e| e["resource"] }
        refute_empty resources

        lisinopril = resources.find { |r| r.dig("medicationCodeableConcept", "text") == "Lisinopril 10mg" }
        assert lisinopril, "expected seeded Lisinopril order in the bundle"

        assert_equal "MedicationRequest", lisinopril["resourceType"]
        assert_equal "1R-O", lisinopril["id"]
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

      DATA_ABSENT_REASON_URL = "http://hl7.org/fhir/StructureDefinition/data-absent-reason"

      test "search entries use data-absent-reason for authoredOn and requester when RPMS does not supply them" do
        RpmsRpc.client.seed_text(:medication_active, "1", <<~WIRE)
          ~OP^1R;O^Lisinopril 10mg^^3271231^3^^^120001^ACTIVE
          \\ Sig: TAKE 1 TABLET BY MOUTH DAILY
          ~OP^42R;O^Metformin 500mg^^3271231^2^^^120042^HOLD
          \\ Sig: TAKE 1 TABLET BY MOUTH TWICE A DAY
        WIRE

        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers

        assert_response :ok
        JSON.parse(response.body)["entry"].each do |entry|
          resource = entry["resource"]
          assert resource["intent"].present?, "intent is required on MedicationRequest"
          assert_nil resource["authoredOn"], "authoredOn must be absent, not invented"
          authored_dar = resource.dig("_authoredOn", "extension")&.find { |ext| ext["url"] == DATA_ABSENT_REASON_URL }
          assert authored_dar, "expected data-absent-reason on _authoredOn"
          assert_equal "unknown", authored_dar["valueCode"]
          refute resource.dig("requester", "reference"), "requester reference must be absent, not invented"
          requester_dar = resource.dig("requester", "extension")&.find { |ext| ext["url"] == DATA_ABSENT_REASON_URL }
          assert requester_dar, "expected data-absent-reason on requester"
          assert_equal "unknown", requester_dar["valueCode"]
        end
      end

      test "search entries expose dosageInstruction text from the order's instruction lines" do
        RpmsRpc.client.seed_text(:medication_active, "1", <<~WIRE)
          ~OP^1R;O^Lisinopril 10mg^^3271231^3^^^120001^ACTIVE
           LISINOPRIL 10MG TAB  Qty: 30 for 30 days
          \\ Sig: TAKE 1 TABLET BY MOUTH
           DAILY
        WIRE

        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers

        assert_response :ok
        lisinopril = JSON.parse(response.body)["entry"]
          .map { |e| e["resource"] }
          .find { |r| r.dig("medicationCodeableConcept", "text") == "Lisinopril 10mg" }
        assert lisinopril, "expected seeded Lisinopril order in the bundle"

        assert_equal "LISINOPRIL 10MG TAB  Qty: 30 for 30 days Sig: TAKE 1 TABLET BY MOUTH DAILY",
                     lisinopril.dig("dosageInstruction", 0, "text")
      end

      test "search entry does not map RPMS stop_date to authoredOn or dispense validityPeriod" do
        stop_date = Date.new(2025, 1, 1)
        RpmsRpc.client.seed_text(:medication_active, "1", <<~WIRE)
          ~OP^99R;O^Aspirin 81mg^^3250101^1^^^120099^
          \\ Sig: TAKE 1 TABLET BY MOUTH DAILY
        WIRE

        get "/lakeraven-ehr/MedicationRequest", params: { patient: "1" }, headers: @headers

        assert_response :ok
        resource = JSON.parse(response.body)["entry"]
          .map { |e| e["resource"] }
          .find { |r| r["id"] == "99R-O" }
        assert resource, "expected seeded medication with stop_date in the bundle"

        assert_equal "unknown", resource["status"]
        assert_nil resource["authoredOn"]
        authored_dar = resource.dig("_authoredOn", "extension")&.find { |ext| ext["url"] == DATA_ABSENT_REASON_URL }
        assert authored_dar, "expected data-absent-reason on _authoredOn"
        assert_equal "unknown", authored_dar["valueCode"]
        refute resource.dig("dispenseRequest", "validityPeriod"),
               "stop_date must not appear as dispenseRequest.validityPeriod"

        serialized = resource.to_json
        [ stop_date.iso8601, RpmsRpc::FilemanDateParser.format_date(stop_date), "3250101" ].each do |fragment|
          refute_includes serialized, fragment,
                          "stop_date must not leak into FHIR resource (#{fragment})"
        end
      end
    end
  end
end
