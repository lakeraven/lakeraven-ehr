# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EprescribingServiceTest < ActiveSupport::TestCase
      setup do
        @adapter = Eprescribing::MockAdapter.new
        @service = EprescribingService.new(adapter: @adapter)
        @_orig_med_for_patient = MedicationRequest.method(:for_patient)
        @_orig_allergy_for_patient = AllergyIntolerance.method(:for_patient)
      end

      teardown do
        MedicationRequest.define_singleton_method(:for_patient, @_orig_med_for_patient)
        AllergyIntolerance.define_singleton_method(:for_patient, @_orig_allergy_for_patient)
      end

      # =========================================================================
      # PRESCRIPTION TRANSMISSION
      # =========================================================================

      test "transmit sends signed prescription via adapter" do
        order = build_signed_medication_order

        result = @service.transmit(order, provider_duz: "789")

        assert result.success?
        assert result.transmission_id.present?
        assert_equal "transmitted", result.status
      end

      test "transmit records adapter transmission" do
        order = build_signed_medication_order

        @service.transmit(order, provider_duz: "789")

        assert_equal 1, @adapter.transmissions.size
      end

      test "transmit creates audit event" do
        order = build_signed_medication_order

        count_before = AuditEvent.count
        @service.transmit(order, provider_duz: "789")
        assert_equal count_before + 1, AuditEvent.count

        event = AuditEvent.last
        assert_equal "E", event.action
        assert_equal "789", event.agent_who_identifier
        assert_match(/Transmission ID:/, event.outcome_desc)
      end

      test "transmit rejects draft order" do
        order = build_medication_order(status: "draft", intent: "plan")

        assert_raises(EprescribingService::PrescriptionNotSignedError) do
          @service.transmit(order, provider_duz: "789")
        end
      end

      test "transmit rejects cancelled order" do
        order = build_medication_order(status: "cancelled", intent: "order")

        assert_raises(EprescribingService::PrescriptionNotActiveError) do
          @service.transmit(order, provider_duz: "789")
        end
      end

      test "failed transmission does not create audit event" do
        order = build_medication_order(status: "draft", intent: "plan")

        count_before = AuditEvent.count
        assert_raises(EprescribingService::PrescriptionNotSignedError) do
          @service.transmit(order, provider_duz: "789")
        end
        assert_equal count_before, AuditEvent.count
      end

      # =========================================================================
      # STATUS CHECKING
      # =========================================================================

      test "check_status returns current status" do
        order = build_signed_medication_order
        tx = @service.transmit(order, provider_duz: "789")

        result = @service.check_status(tx.transmission_id)

        assert result.success?
        assert_equal "transmitted", result.status
      end

      test "check_status returns delivered after delivery" do
        order = build_signed_medication_order
        tx = @service.transmit(order, provider_duz: "789")
        @adapter.simulate_delivery(tx.transmission_id)

        result = @service.check_status(tx.transmission_id)

        assert result.success?
        assert_equal "delivered", result.status
        assert result.transmitted?
      end

      test "check_status fails for unknown transmission" do
        result = @service.check_status("nonexistent-id")

        assert_not result.success?
        assert_equal "error", result.status
      end

      # =========================================================================
      # PRESCRIPTION CANCELLATION
      # =========================================================================

      test "cancel cancels a transmitted prescription" do
        order = build_signed_medication_order
        tx = @service.transmit(order, provider_duz: "789")

        result = @service.cancel(tx.transmission_id, provider_duz: "789", reason: "Patient request")

        assert result.success?
        assert_equal "cancelled", result.status
      end

      test "cancel records cancellation in adapter" do
        order = build_signed_medication_order
        tx = @service.transmit(order, provider_duz: "789")

        @service.cancel(tx.transmission_id, provider_duz: "789", reason: "Allergy discovered")

        assert_equal 1, @adapter.cancellations.size
        assert_equal "Allergy discovered", @adapter.cancellations.first[:reason]
      end

      test "cancel creates audit event" do
        order = build_signed_medication_order
        tx = @service.transmit(order, provider_duz: "789")

        count_before = AuditEvent.count
        @service.cancel(tx.transmission_id, provider_duz: "789", reason: "Allergy discovered")
        assert_equal count_before + 1, AuditEvent.count

        event = AuditEvent.last
        assert_equal "D", event.action
        assert_match(/Reason: Allergy discovered/, event.outcome_desc)
      end

      test "cancel without reason omits reason from audit" do
        order = build_signed_medication_order
        tx = @service.transmit(order, provider_duz: "789")

        @service.cancel(tx.transmission_id, provider_duz: "789")

        event = AuditEvent.last
        assert_equal "D", event.action
        assert_no_match(/Reason:/, event.outcome_desc)
      end

      test "cancel fails for unknown transmission" do
        result = @service.cancel("nonexistent-id", provider_duz: "789")

        assert_not result.success?
      end

      test "failed cancel does not create audit event" do
        count_before = AuditEvent.count
        @service.cancel("nonexistent-id", provider_duz: "789")
        assert_equal count_before, AuditEvent.count
      end

      # =========================================================================
      # TRANSMISSION RESULT
      # =========================================================================

      test "TransmissionResult success creates successful result" do
        result = Eprescribing::TransmissionResult.success(transmission_id: "erx-123")

        assert result.success?
        assert result.transmitted?
        assert_equal "erx-123", result.transmission_id
        assert_empty result.errors
      end

      test "TransmissionResult failure creates failed result" do
        result = Eprescribing::TransmissionResult.failure("Network error")

        assert_not result.success?
        assert_not result.transmitted?
        assert_equal [ "Network error" ], result.errors
      end

      # =========================================================================
      # CPOE SERVICE INTEGRATION
      # =========================================================================

      test "CpoeService sign_order transmits medication prescription" do
        mock_no_medications("12345")
        mock_no_allergies("12345")

        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        sign_result = CpoeService.sign_order(result.order, provider_duz: "789")

        assert sign_result.success?
        assert sign_result.erx_result.present?
        assert sign_result.erx_result.success?
      end

      test "CpoeService sign_order skips transmission when transmit false" do
        mock_no_medications("12345")
        mock_no_allergies("12345")

        result = CpoeService.create_medication_order(
          patient_dfn: "12345",
          provider_duz: "789",
          medication: "Lisinopril 10mg"
        )

        sign_result = CpoeService.sign_order(result.order, provider_duz: "789", transmit: false)

        assert sign_result.success?
        assert_nil sign_result.erx_result
      end

      test "CpoeService sign_order does not transmit lab orders" do
        sign_result = CpoeService.sign_order(
          build_cpoe_lab_order,
          provider_duz: "789"
        )

        assert sign_result.success?
        assert_nil sign_result.erx_result
      end

      # =========================================================================
      # ADAPTER FACTORY
      # =========================================================================

      test "factory builds mock adapter in test" do
        adapter = Eprescribing::EprescribingAdapterFactory.build(:mock)
        assert_equal :mock, adapter.mode
      end

      private

      def build_medication_order(status: "active", intent: "order")
        MedicationRequest.new(
          ien: "med-#{SecureRandom.hex(4)}",
          patient_dfn: "12345",
          requester_duz: "789",
          medication_display: "Lisinopril 10mg",
          medication_code: "197884",
          status: status,
          intent: intent,
          dosage_instruction: "Take 1 tablet daily",
          route: "oral",
          frequency: "daily",
          dispense_quantity: "30",
          refills: "3",
          days_supply: "30",
          authored_on: Time.current
        )
      end

      def build_signed_medication_order
        build_medication_order(status: "active", intent: "order")
      end

      def build_cpoe_lab_order
        CpoeOrder.new(
          id: "cpoe-#{SecureRandom.hex(8)}",
          patient_dfn: "12345",
          requester_duz: "789",
          status: "draft",
          intent: "plan",
          category: "laboratory",
          priority: "routine",
          code: "58410-2",
          code_display: "CBC",
          clinical_reason: "Screening",
          authored_on: Time.current
        )
      end

      def mock_no_medications(dfn)
        MedicationRequest.define_singleton_method(:for_patient) do |patient_dfn, **_opts|
          []
        end
      end

      def mock_no_allergies(dfn)
        AllergyIntolerance.define_singleton_method(:for_patient) do |patient_dfn|
          []
        end
      end
    end
  end
end
