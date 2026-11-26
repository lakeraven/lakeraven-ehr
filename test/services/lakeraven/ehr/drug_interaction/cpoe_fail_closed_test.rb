# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/drug_interaction_adapter_test_helper"

module Lakeraven
  module EHR
    module DrugInteraction
      class CpoeFailClosedTest < ActiveSupport::TestCase
        include DrugInteractionAdapterTestHelper

        setup do
          @_orig_rpms_client = RpmsRpc.configuration.client
          RpmsStandIn.install_baseline!
          @_orig_allergy_for_patient = AllergyIntolerance.method(:for_patient)
          mock_no_allergies("12345")

          @original_backend_env = ENV["DRUG_INTERACTION_BACKEND"]
          @original_rails_env = Rails.env
          reset_drug_interaction_adapter_registrations!
        end

        teardown do
          RpmsRpc.configure { |c| c.client = @_orig_rpms_client }
          AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy_for_patient)
          ENV["DRUG_INTERACTION_BACKEND"] = @original_backend_env
          Rails.env = @original_rails_env
          reset_drug_interaction_adapter_registrations!
        end

        test "medication order with unavailable interaction backend exposes incomplete interaction_result" do
          ENV["DRUG_INTERACTION_BACKEND"] = "rpms"
          seed_active_medications("12345", [
            { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" }
          ])

          result = CpoeService.create_medication_order(
            patient_dfn: "12345",
            provider_duz: "789",
            medication: "Ibuprofen 400mg"
          )

          assert result.success?
          checked = result.interaction_result
          assert checked.incomplete?
          refute checked.safe?
          assert_empty checked.interactions
          assert_equal UNAVAILABLE_INCOMPLETE_REASON, checked.incomplete_reason
        end

        test "medication order when adapter builder raises still succeeds with incomplete interaction_result" do
          drug_interaction_adapter_factory.register(:rpms) { raise "broker down" }
          ENV["DRUG_INTERACTION_BACKEND"] = "rpms"
          seed_active_medications("12345", [
            { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" }
          ])

          result = CpoeService.create_medication_order(
            patient_dfn: "12345",
            provider_duz: "789",
            medication: "Ibuprofen 400mg"
          )

          assert result.success?
          checked = result.interaction_result
          assert checked.incomplete?
          refute checked.safe?
          assert_empty checked.interactions
          assert_equal :rpms, checked.decision_source
          assert_equal BUILDER_FAILURE_INCOMPLETE_REASON, checked.incomplete_reason
          refute_includes checked.incomplete_reason, "broker down"
        end

        private

        # The patient's orders, each as RpmsRpc::Medication.active_for_patient
        # returns it, read back through the gateway: order id, drug, the RPMS
        # status, stop date and the sig line.
        def seed_active_medications(dfn, orders)
          rows = orders.each_with_index.map do |order, i|
            { order_id: "#{4401 + i}R;O", type: "OP", name: order[:drug_name], status: order[:status],
              stop_date: Date.new(2027, 12, 31), instructions: [ "Sig: TAKE AS DIRECTED" ], comments: [] }
          end
          RpmsStandIn.answer(RpmsRpc::Medication, :active_for_patient, dfn, with: rows)
        end

        def mock_no_allergies(dfn)
          AllergyIntolerance.define_singleton_method(:for_patient) do |_patient_dfn|
            []
          end
        end
      end
    end
  end
end
