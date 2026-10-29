# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class ClinicalDecisionSupportFailClosedTest < ActiveSupport::TestCase
        include DrugInteractionAdapterTestHelper

        setup do
          @_orig_rpms_client = RpmsRpc.configuration.client
          RpmsRpc.mock!(&BASELINE_MOCK_SEEDS)
          @_orig_allergy_for_patient = AllergyIntolerance.method(:for_patient)
          mock_no_allergies("12345")

          @original_backend_env = ENV["DRUG_INTERACTION_BACKEND"]
          @original_rails_env = Rails.env
          ClinicalDecisionSupportService.reload_rules!
          ClinicalDecisionSupportService.rule_overrides.clear
          reset_drug_interaction_adapter_registrations!
        end

        teardown do
          RpmsRpc.configure { |c| c.client = @_orig_rpms_client }
          AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy_for_patient)
          ENV["DRUG_INTERACTION_BACKEND"] = @original_backend_env
          Rails.env = @original_rails_env
          ClinicalDecisionSupportService.reload_rules!
          ClinicalDecisionSupportService.rule_overrides.clear
          reset_drug_interaction_adapter_registrations!
        end

        test "evaluate_medication with unavailable backend surfaces incomplete check alert" do
          ENV["DRUG_INTERACTION_BACKEND"] = "rpms"
          seed_active_medications("12345", [
            { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" }
          ])

          result = ClinicalDecisionSupportService.evaluate_medication("12345", "Ibuprofen 400mg")

          assert_empty result.alerts_by_category("drug-interaction")

          incomplete_alerts = result.alerts_by_category("drug-interaction-check-incomplete")
          assert_equal 1, incomplete_alerts.length

          alert = incomplete_alerts.first
          assert_equal "drug-interaction-check-incomplete", alert[:category]
          assert_equal "high", alert[:severity]
          assert_equal CDS_UNAVAILABLE_INCOMPLETE_ALERT_MESSAGE, alert[:message]
          assert_equal "DrugInteractionService", alert[:source]
          assert alert.key?(:id)
          assert alert[:id].present?
        end

        test "evaluate_medication with adapter check failure uses generic incomplete alert message" do
          failing_adapter = Class.new(BaseAdapter) do
            define_method(:backend) { :rpms }
            define_method(:check_interactions) { |_| raise IOError, "RPC timeout for DFN 123" }
            define_method(:check_allergies) { |_, _| [] }
          end
          drug_interaction_adapter_factory.register(:rpms) { failing_adapter.new }
          ENV["DRUG_INTERACTION_BACKEND"] = "rpms"
          seed_active_medications("12345", [
            { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" }
          ])

          result = ClinicalDecisionSupportService.evaluate_medication("12345", "Ibuprofen 400mg")

          assert_empty result.alerts_by_category("drug-interaction")
          incomplete_alerts = result.alerts_by_category("drug-interaction-check-incomplete")
          assert_equal 1, incomplete_alerts.length
          alert = incomplete_alerts.first
          assert_equal CDS_GENERIC_INCOMPLETE_ALERT_MESSAGE, alert[:message]
          refute_includes alert[:message], "RPC timeout"
          refute_includes alert[:message], "not available on this server"
        end

        test "evaluate_medication when medication fetch fails does not treat empty data as a complete check" do
          ENV.delete("DRUG_INTERACTION_BACKEND")
          original = MedicationRequest.method(:checked_for_patient)
          MedicationRequest.define_singleton_method(:checked_for_patient) { |_dfn| raise "medication gateway down" }

          result = ClinicalDecisionSupportService.evaluate_medication("12345", "Ibuprofen 400mg")

          assert_empty result.alerts_by_category("drug-interaction")
          incomplete_alerts = result.alerts_by_category("drug-interaction-check-incomplete")
          assert_equal 1, incomplete_alerts.length
          assert_equal CDS_DATA_FETCH_INCOMPLETE_ALERT_MESSAGE, incomplete_alerts.first[:message]
        ensure
          MedicationRequest.define_singleton_method(:checked_for_patient, original)
        end

        test "evaluate_medication when allergy fetch fails does not treat empty data as a complete check" do
          ENV.delete("DRUG_INTERACTION_BACKEND")
          seed_active_medications("12345", [
            { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" }
          ])
          original = SupplementalClinicalResources.method(:merged_allergy_intolerances_for_patient)
          SupplementalClinicalResources.define_singleton_method(:merged_allergy_intolerances_for_patient) do |_dfn|
            raise "allergy gateway down"
          end

          result = ClinicalDecisionSupportService.evaluate_medication("12345", "Ibuprofen 400mg")

          assert_empty result.alerts_by_category("drug-interaction")
          incomplete_alerts = result.alerts_by_category("drug-interaction-check-incomplete")
          assert_equal 1, incomplete_alerts.length
          assert_equal CDS_DATA_FETCH_INCOMPLETE_ALERT_MESSAGE, incomplete_alerts.first[:message]
        ensure
          SupplementalClinicalResources.define_singleton_method(:merged_allergy_intolerances_for_patient, original)
        end

        test "registered builder failure surfaces single high incomplete alert without broker message" do
          drug_interaction_adapter_factory.register(:rpms) { raise "broker down" }
          ENV["DRUG_INTERACTION_BACKEND"] = "rpms"
          seed_active_medications("12345", [
            { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" }
          ])

          result = ClinicalDecisionSupportService.evaluate_medication("12345", "Ibuprofen 400mg")

          incomplete_alerts = result.alerts_by_category("drug-interaction-check-incomplete")
          assert_equal 1, incomplete_alerts.length
          assert_equal "high", incomplete_alerts.first[:severity]
          assert_equal CDS_GENERIC_INCOMPLETE_ALERT_MESSAGE, incomplete_alerts.first[:message]
          assert_empty result.alerts_by_category("drug-interaction")
        end

        test "evaluate_medication with default backend returns drug-interaction alerts without incomplete alert" do
          ENV.delete("DRUG_INTERACTION_BACKEND")
          seed_active_medications("12345", [
            { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" }
          ])

          result = ClinicalDecisionSupportService.evaluate_medication("12345", "Ibuprofen 400mg")

          assert result.has_alerts?
          assert_empty result.alerts_by_category("drug-interaction-check-incomplete")

          drug_alerts = result.alerts_by_category("drug-interaction")
          assert_equal 1, drug_alerts.length

          alert = drug_alerts.first
          assert_equal "drug-interaction", alert[:category]
          assert_equal "high", alert[:severity]
          assert_equal "DrugInteractionService", alert[:source]
          assert_equal "clinical-database", alert[:evidence_level]
          assert_includes alert[:message], "WARFARIN 5MG TAB"
          assert_includes alert[:message], "Ibuprofen 400mg"
          assert_includes alert[:message], "NSAIDs increase anticoagulant effect of warfarin"
          assert alert.key?(:recommendation)
          assert alert.key?(:details)
          assert alert.key?(:created_at)
        end

        private

        def seed_active_medications(dfn, orders)
          wire = orders.each_with_index.map do |order, i|
            "~OP^#{4401 + i}R;O^#{order[:drug_name]}^^3271231^3^^^#{120345 + i}^#{order[:status]}\n\\ Sig: TAKE AS DIRECTED"
          end
          RpmsRpc.client.seed_text(:medication_active, dfn.to_s, wire.join("\n"))
        end

        def mock_no_allergies(_dfn)
          AllergyIntolerance.define_singleton_method(:for_patient) do |_patient_dfn|
            []
          end
        end
      end
    end
  end
end
