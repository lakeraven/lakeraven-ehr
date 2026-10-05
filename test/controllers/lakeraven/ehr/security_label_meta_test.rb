# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    # GATE SPEC — ORHC Booth Demo Spec v1.1 §1 rule 1 and §5 (meta.security HTEST only).
    class SecurityLabelMetaTest < ActionDispatch::IntegrationTest
      include SmartAuthTestHelper

      HTEST_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-ActReason"
      SITE_IEN = 5001

      setup do
        setup_smart_auth(
          scopes: "system/Patient.read system/Condition.read system/Observation.read",
          organization_id: "rpms-organization-#{SITE_IEN}"
        )
        seed_patient_and_clinical_rows!
      end

      teardown do
        teardown_smart_auth
        Condition.gateway = nil
        Observation.gateway = nil
        Lakeraven::EHR.configuration.supplemental_observations_provider = nil
      end

      # Catches serializers that only emit meta.profile and omit HTEST security.
      test "Patient read carries HTEST security alongside profile" do
        get "/lakeraven-ehr/Patient/9101", headers: @headers
        assert_response :ok
        assert_orhc_htest_meta!(JSON.parse(response.body))
      end

      # Catches meta stamping on RPC-backed types only while supplemental types stay bare.
      test "Condition search entries carry HTEST security" do
        get "/lakeraven-ehr/Condition", params: {patient: "9101"}, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        refute_empty body["entry"], "need at least one Condition to assert meta"
        body["entry"].each do |entry|
          assert_orhc_htest_meta!(entry["resource"])
        end
      end

      # Catches meta omitted on supplemental observations served beside vitals.
      test "Observation search entries carry HTEST security" do
        get "/lakeraven-ehr/Observation", params: {patient: "9101", code: "2345-7"}, headers: @headers
        assert_response :ok
        body = JSON.parse(response.body)
        refute_empty body["entry"], "need at least one Observation to assert meta"
        body["entry"].each do |entry|
          assert_orhc_htest_meta!(entry["resource"])
        end
      end

      private

      def assert_orhc_htest_meta!(resource)
        meta = resource["meta"]
        refute_nil meta, "expected meta on #{resource["resourceType"]}/#{resource["id"]}"
        assert meta["profile"].present?, "US Core profile must remain alongside HTEST"

        security = Array(meta["security"])
        htest = security.find { |c| c["code"] == "HTEST" && c["system"] == HTEST_SYSTEM }
        refute_nil htest, "missing meta.security HTEST on #{resource["resourceType"]}/#{resource["id"]}"
        refute Array(meta["tag"]).any? { |t| t["code"] == "orhc-2026-demo" },
          "per-resource meta.tag must not be invented (§1 rule 1)"
      end

      def seed_patient_and_clinical_rows!
        client = RpmsRpc.client
        client.seed(:patient_select, "9101", {
          name: "Kessler,Pat", sex: "F", dob: Date.parse("1959-04-12"),
          ssn: "900-00-9101", age: 67
        })
        client.seed(:patient_id_info, "9101", {
          ssn: "900-00-9101", dob: Date.parse("1959-04-12"), sex: "F",
          race_code: "I", site_ien: SITE_IEN, name: "Kessler,Pat"
        })

        Condition.gateway = Class.new do
          def for_patient(_dfn)
            [
              {ien: "cond-orhc-a-i10", status: "A", icd_code: "I10",
               description: "Essential hypertension", onset_date: Date.new(2019, 3, 1),
               recorded_date: Date.new(2019, 3, 1)}
            ]
          end
        end.new

        Lakeraven::EHR.configuration.supplemental_observations_provider = ->(_dfn) {
          [
            Observation.new(
              ien: "obs-orhc-a-glu-fix", patient_dfn: "9101", code: "2345-7",
              code_system: "loinc", display: "Glucose", value_quantity: "142",
              unit: "mg/dL", category: "laboratory", status: "corrected",
              effective_datetime: DateTime.new(2026, 9, 22, 8, 5, 0, "-7")
            )
          ]
        }
      end
    end
  end
end
