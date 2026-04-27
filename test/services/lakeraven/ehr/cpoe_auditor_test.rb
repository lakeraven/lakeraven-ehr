# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CpoeAuditorTest < ActiveSupport::TestCase
      setup do
        @_orig_med_for_patient = MedicationRequest.method(:for_patient)
        @_orig_allergy_for_patient = AllergyIntolerance.method(:for_patient)
        mock_no_medications("12345")
        mock_no_allergies("12345")
      end

      teardown do
        MedicationRequest.define_singleton_method(:for_patient, @_orig_med_for_patient)
        AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy_for_patient)
      end

      # =========================================================================
      # MEDICATION ORDER AUDIT EVENTS
      # =========================================================================

      test "medication order creation emits audit event" do
        assert_difference "AuditEvent.count", 1 do
          CpoeService.create_medication_order(
            patient_dfn: "12345",
            provider_duz: "789",
            medication: "Lisinopril 10mg"
          )
        end

        event = AuditEvent.last
        assert_equal "application", event.event_type
        assert_equal "C", event.action
        assert_equal "0", event.outcome
        assert_equal "Practitioner", event.agent_who_type
        assert_equal "789", event.agent_who_identifier
        assert_equal "MedicationRequest", event.entity_type
      end

      test "medication order signing emits audit event with content hash" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        assert_difference "AuditEvent.count", 1 do
          CpoeService.sign_order(result.order, provider_duz: "789", transmit: false)
        end

        event = AuditEvent.last
        assert_equal "E", event.action
        assert_match(/Content hash:/, event.outcome_desc)
      end

      test "medication order cancellation emits audit event" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        assert_difference "AuditEvent.count", 1 do
          CpoeService.cancel_order(result.order, provider_duz: "789", reason: "contraindicated")
        end

        event = AuditEvent.last
        assert_equal "D", event.action
        assert_match(/contraindicated/, event.outcome_desc)
      end

      # =========================================================================
      # LAB ORDER AUDIT EVENTS
      # =========================================================================

      test "lab order creation emits audit event" do
        assert_difference "AuditEvent.count", 1 do
          CpoeService.create_lab_order(
            patient_dfn: "12345",
            provider_duz: "789",
            test_name: "Complete Blood Count",
            test_code: "58410-2"
          )
        end

        event = AuditEvent.last
        assert_equal "C", event.action
        assert_equal "ServiceRequest", event.entity_type
      end

      test "lab order signing emits audit event" do
        result = CpoeService.create_lab_order(
          patient_dfn: "12345",
          provider_duz: "789",
          test_name: "CBC",
          test_code: "58410-2"
        )

        assert_difference "AuditEvent.count", 1 do
          CpoeService.sign_order(result.order, provider_duz: "789")
        end

        event = AuditEvent.last
        assert_equal "E", event.action
      end

      # =========================================================================
      # IMAGING ORDER AUDIT EVENTS
      # =========================================================================

      test "imaging order creation emits audit event" do
        assert_difference "AuditEvent.count", 1 do
          CpoeService.create_imaging_order(
            patient_dfn: "12345",
            provider_duz: "789",
            study_type: "Chest X-Ray",
            body_site: "Chest"
          )
        end

        event = AuditEvent.last
        assert_equal "C", event.action
      end

      test "imaging order cancellation emits audit event without reason" do
        result = CpoeService.create_imaging_order(
          patient_dfn: "12345",
          provider_duz: "789",
          study_type: "Chest X-Ray"
        )

        assert_difference "AuditEvent.count", 1 do
          CpoeService.cancel_order(result.order, provider_duz: "789")
        end

        event = AuditEvent.last
        assert_equal "D", event.action
      end

      # =========================================================================
      # FAILED OPERATIONS DO NOT EMIT EVENTS
      # =========================================================================

      test "failed medication order does not emit audit event" do
        assert_no_difference "AuditEvent.count" do
          CpoeService.create_medication_order(
            patient_dfn: nil,
            provider_duz: "789",
            medication: "Lisinopril 10mg"
          )
        end
      end

      test "failed lab order does not emit audit event" do
        assert_no_difference "AuditEvent.count" do
          CpoeService.create_lab_order(
            patient_dfn: "12345",
            provider_duz: "789",
            test_name: nil
          )
        end
      end

      test "failed imaging order does not emit audit event" do
        assert_no_difference "AuditEvent.count" do
          CpoeService.create_imaging_order(
            patient_dfn: "12345",
            provider_duz: "789",
            study_type: nil
          )
        end
      end

      # =========================================================================
      # CONTENT HASH CONSISTENCY
      # =========================================================================

      test "different orders produce different content hashes" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )
        CpoeService.sign_order(result.order, provider_duz: "789", transmit: false)
        hash1 = AuditEvent.last.outcome_desc

        result2 = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Metformin 500mg"
        )
        CpoeService.sign_order(result2.order, provider_duz: "789", transmit: false)
        hash2 = AuditEvent.last.outcome_desc

        assert_not_equal hash1, hash2
      end

      test "signing the same order twice produces consistent content hash" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        CpoeService.sign_order(result.order, provider_duz: "789", transmit: false)
        hash1 = AuditEvent.last.outcome_desc

        CpoeService.sign_order(result.order, provider_duz: "789", transmit: false)
        hash2 = AuditEvent.last.outcome_desc

        assert_equal hash1, hash2
      end

      # =========================================================================
      # GENERIC EVENT RECORDING
      # =========================================================================

      test "trail_for returns ordered audit events for an order" do
        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )
        order_id = CpoeAuditor.send(:order_id, result.order)

        CpoeService.sign_order(result.order, provider_duz: "789", transmit: false)

        trail = CpoeAuditor.trail_for(order_id)

        assert_equal 2, trail.count
      end

      test "record_event creates a generic CPOE audit event" do
        CpoeAuditor.record_event(
          type: "application",
          subtype: "custom_action",
          action: "E",
          provider_duz: "789",
          description: "Custom CPOE action"
        )

        event = AuditEvent.last
        assert_equal "application", event.event_type
        assert_equal "E", event.action
        assert_equal "789", event.agent_who_identifier
        assert_match(/custom_action/, event.outcome_desc)
      end

      private

      def mock_no_medications(_dfn)
        MedicationRequest.define_singleton_method(:for_patient) do |_patient_dfn, **_opts|
          []
        end
      end

      def mock_no_allergies(_dfn)
        AllergyIntolerance.define_singleton_method(:for_patient) do |_patient_dfn|
          []
        end
      end
    end
  end
end
