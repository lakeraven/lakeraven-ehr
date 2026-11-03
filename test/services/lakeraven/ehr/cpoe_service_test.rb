# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CpoeServiceTest < ActiveSupport::TestCase
      setup do
        @_orig_rpms_client = RpmsRpc.configuration.client
        RpmsRpc.mock!(&BASELINE_MOCK_SEEDS)
        @_orig_allergy_for_patient = AllergyIntolerance.method(:for_patient)
        mock_no_allergies("12345")
      end

      teardown do
        RpmsRpc.configure { |c| c.client = @_orig_rpms_client }
        AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy_for_patient)
      end

      # =========================================================================
      # MEDICATION ORDERS
      # =========================================================================

      test "creates a medication order" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg",
          dosage: "Take 1 tablet by mouth daily",
          route: "oral",
          frequency: "QD",
          quantity: 30,
          refills: 3
        )

        assert result.success?
        assert_equal "draft", result.order.status
        assert_equal "Lisinopril 10mg", result.order.medication_display
        assert_equal "12345", result.order.patient_dfn
        assert_equal "789", result.order.requester_duz
      end

      test "medication order triggers interaction check" do
        seed_active_medications("12345", [
          { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" }
        ])

        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Ibuprofen 400mg"
        )

        assert result.success?
        assert result.has_interaction_alerts?
        assert_equal "draft", result.order.status
      end

      test "medication interaction check weighs active and held orders, not discontinued ones (#680)" do
        seed_active_medications("12345", [
          { drug_name: "WARFARIN 5MG TAB", status: "ACTIVE" },
          { drug_name: "METHOTREXATE 2.5MG TAB", status: "DISCONTINUED" },
          { drug_name: "LITHIUM CARBONATE 300MG CAP", status: "HOLD" }
        ])

        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Ibuprofen 400mg"
        )

        checked = result.interaction_result
        refute checked.incomplete?, checked.incomplete_reason
        drugs = checked.interactions.flat_map { |i| [ i.drug_a, i.drug_b ] }
        assert_includes drugs, "WARFARIN 5MG TAB"
        assert_includes drugs, "LITHIUM CARBONATE 300MG CAP"
        refute_includes drugs, "METHOTREXATE 2.5MG TAB"
      end

      test "medication order with no interactions has empty alerts" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        assert result.success?
        assert_not result.has_interaction_alerts?
      end

      test "sign medication order changes status to active" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        signed = CpoeService.sign_order(result.order, provider_duz: "789")

        assert signed.success?
        assert_equal "active", signed.order.status
        assert_equal "order", signed.order.intent
      end

      test "cancel medication order changes status to cancelled" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        cancelled = CpoeService.cancel_order(result.order, reason: "contraindicated interaction")

        assert cancelled.success?
        assert_equal "cancelled", cancelled.order.status
      end

      test "medication order requires patient_dfn" do
        result = CpoeService.create_medication_order(
          patient_dfn: nil,
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        assert_not result.success?
        assert_includes result.errors, "Patient is required"
      end

      test "medication order requires medication name" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: nil
        )

        assert_not result.success?
        assert_includes result.errors, "Medication is required"
      end

      # =========================================================================
      # LABORATORY ORDERS
      # =========================================================================

      test "creates a lab order" do
        result = CpoeService.create_lab_order(
          patient_dfn: "12345",
          provider_duz: "789",
          test_name: "Complete Blood Count",
          test_code: "58410-2",
          priority: "routine",
          clinical_reason: "Annual screening"
        )

        assert result.success?
        assert_equal "draft", result.order.status
        assert_equal "laboratory", result.order.category
        assert_equal "Complete Blood Count", result.order.code_display
      end

      test "creates a stat lab order" do
        result = CpoeService.create_lab_order(
          patient_dfn: "12345",
          provider_duz: "789",
          test_name: "Basic Metabolic Panel",
          test_code: "51990-0",
          priority: "stat",
          clinical_reason: "Acute renal assessment"
        )

        assert result.success?
        assert_equal "stat", result.order.priority
      end

      test "sign lab order changes status to active" do
        result = CpoeService.create_lab_order(
          patient_dfn: "12345",
          provider_duz: "789",
          test_name: "CBC",
          test_code: "58410-2"
        )

        signed = CpoeService.sign_order(result.order, provider_duz: "789")

        assert signed.success?
        assert_equal "active", signed.order.status
      end

      test "lab order requires test name" do
        result = CpoeService.create_lab_order(
          patient_dfn: "12345",
          provider_duz: "789",
          test_name: nil
        )

        assert_not result.success?
        assert_includes result.errors, "Test name is required"
      end

      # =========================================================================
      # IMAGING ORDERS
      # =========================================================================

      test "creates an imaging order" do
        result = CpoeService.create_imaging_order(
          patient_dfn: "12345",
          provider_duz: "789",
          study_type: "Chest X-Ray",
          body_site: "Chest",
          laterality: "bilateral",
          clinical_reason: "Cough, rule out pneumonia",
          priority: "routine"
        )

        assert result.success?
        assert_equal "draft", result.order.status
        assert_equal "imaging", result.order.category
        assert_equal "Chest X-Ray", result.order.code_display
      end

      test "sign imaging order changes status to active" do
        result = CpoeService.create_imaging_order(
          patient_dfn: "12345",
          provider_duz: "789",
          study_type: "Chest X-Ray",
          body_site: "Chest"
        )

        signed = CpoeService.sign_order(result.order, provider_duz: "789")

        assert signed.success?
        assert_equal "active", signed.order.status
      end

      test "imaging order requires study type" do
        result = CpoeService.create_imaging_order(
          patient_dfn: "12345",
          provider_duz: "789",
          study_type: nil
        )

        assert_not result.success?
        assert_includes result.errors, "Study type is required"
      end

      # =========================================================================
      # FHIR SERIALIZATION
      # =========================================================================

      test "medication order serializes to FHIR MedicationRequest" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        assert_equal "MedicationRequest", result.order.class.resource_class
      end

      test "lab order serializes to FHIR ServiceRequest" do
        result = CpoeService.create_lab_order(
          patient_dfn: "12345",
          provider_duz: "789",
          test_name: "CBC",
          test_code: "58410-2"
        )

        fhir = result.order.to_fhir
        assert_equal "ServiceRequest", fhir[:resourceType]
      end

      private

      # The patient's orders as ORWPS ACTIVE wire, read back through the
      # gateway and the rpms-rpc parser: order id, drug, expiration, refills,
      # CPRS order number, the RPMS status (piece 9), then the sig line.
      def seed_active_medications(dfn, orders)
        wire = orders.each_with_index.map do |order, i|
          "~OP^#{4401 + i}R;O^#{order[:drug_name]}^^3271231^3^^^#{120345 + i}^#{order[:status]}\n\\ Sig: TAKE AS DIRECTED"
        end
        RpmsRpc.client.seed_text(:medication_active, dfn.to_s, wire.join("\n"))
      end

      def mock_no_allergies(dfn)
        AllergyIntolerance.define_singleton_method(:for_patient) do |patient_dfn|
          []
        end
      end
    end
  end
end
