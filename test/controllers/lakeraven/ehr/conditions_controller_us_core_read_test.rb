# frozen_string_literal: true

require "test_helper"
require_relative "../../../dummy/lib/lakeraven_demo_seeds"

module Lakeraven
  module EHR
    class ConditionsControllerUsCoreReadTest < ActionDispatch::IntegrationTest
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

      test "search entries serialize problem-list rows as FHIR Condition resources" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers

        assert_response :ok
        resources = JSON.parse(response.body)["entry"].map { |e| e["resource"] }
        refute_empty resources

        diabetes = resources.find { |r| r.dig("code", "coding", 0, "code") == "E11.9" }
        assert diabetes, "expected seeded Type 2 diabetes problem in the bundle"

        assert_equal "Condition", diabetes["resourceType"]
        assert_equal "1", diabetes["id"]
        assert_equal "Patient/1", diabetes.dig("subject", "reference")
        assert_equal "Type 2 diabetes mellitus", diabetes.dig("code", "text")
        assert_equal "http://hl7.org/fhir/sid/icd-10-cm", diabetes.dig("code", "coding", 0, "system")
        assert_equal "active", diabetes.dig("clinicalStatus", "coding", 0, "code")
        assert_equal "http://terminology.hl7.org/CodeSystem/condition-clinical",
                     diabetes.dig("clinicalStatus", "coding", 0, "system")
        assert_equal "problem-list-item", diabetes.dig("category", 0, "coding", 0, "code")
        assert_equal "http://terminology.hl7.org/CodeSystem/condition-category",
                     diabetes.dig("category", 0, "coding", 0, "system")
      end

      test "search entries omit raw RPMS problem-list field names" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers

        assert_response :ok
        JSON.parse(response.body)["entry"].each do |entry|
          resource = entry["resource"]
          refute resource.key?("icd_code"), "gateway icd_code must not appear on the FHIR resource"
          refute resource.key?("description"), "gateway description must not appear on the FHIR resource"
          refute resource.key?("status"), "gateway problem status code must not appear on the FHIR resource"
        end
      end

      test "search entries map seeded active problem to clinicalStatus active" do
        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers

        assert_response :ok
        resources = JSON.parse(response.body)["entry"].map { |e| e["resource"] }

        diabetes = resources.find { |r| r.dig("code", "coding", 0, "code") == "E11.9" }
        assert diabetes, "expected seeded Type 2 diabetes problem in the bundle"
        assert_equal "active", diabetes.dig("clinicalStatus", "coding", 0, "code")

        hypertension = resources.find { |r| r.dig("code", "coding", 0, "code") == "I10" }
        assert hypertension, "expected seeded hypertension problem in the bundle"
        assert_equal "active", hypertension.dig("clinicalStatus", "coding", 0, "code")
      end

      DATA_ABSENT_REASON_URL = "http://hl7.org/fhir/StructureDefinition/data-absent-reason"

      test "search entries map seeded inactive problem to clinicalStatus inactive" do
        RpmsRpc.client.seed_keyed_collection(:problem_list, "1",
          [ { ien: 1, status: "A", icd_code: "E11.9", description: "Type 2 diabetes mellitus" },
            { ien: 99, status: "I", icd_code: "J44.9", description: "Chronic obstructive pulmonary disease" } ])

        get "/lakeraven-ehr/Condition", params: { patient: "1" }, headers: @headers

        assert_response :ok
        copd = JSON.parse(response.body)["entry"]
          .map { |e| e["resource"] }
          .find { |r| r.dig("code", "coding", 0, "code") == "J44.9" }
        assert copd, "expected seeded inactive problem in the bundle"
        assert_equal "inactive", copd.dig("clinicalStatus", "coding", 0, "code")
      end
    end
  end
end
