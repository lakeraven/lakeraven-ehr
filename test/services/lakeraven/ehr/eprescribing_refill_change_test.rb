# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class EprescribingRefillChangeTest < ActiveSupport::TestCase
      setup do
        @adapter = Eprescribing::MockAdapter.new
        @service = EprescribingService.new(adapter: @adapter)
        @order = build_signed_order
        @tx = @service.transmit(@order, provider_duz: "789")
      end

      # =========================================================================
      # REFILL REQUESTS
      # =========================================================================

      test "request_refill creates a pending refill" do
        result = @service.request_refill(@tx.transmission_id, pharmacy_ncpdpid: "1234567")

        assert result.success?
        assert_equal "pending", result.status
        assert result.transmission_id.present?
      end

      test "approve_refill changes status to approved" do
        refill = @service.request_refill(@tx.transmission_id, pharmacy_ncpdpid: "1234567")
        result = @service.approve_refill(refill.transmission_id, provider_duz: "789")

        assert result.success?
        assert_equal "approved", result.status
      end

      test "approve_refill creates audit event" do
        refill = @service.request_refill(@tx.transmission_id, pharmacy_ncpdpid: "1234567")

        count_before = AuditEvent.count
        @service.approve_refill(refill.transmission_id, provider_duz: "789")
        assert_equal count_before + 1, AuditEvent.count

        event = AuditEvent.last
        assert_match(/refill/i, event.outcome_desc)
      end

      test "deny_refill changes status to denied" do
        refill = @service.request_refill(@tx.transmission_id, pharmacy_ncpdpid: "1234567")
        result = @service.deny_refill(refill.transmission_id, provider_duz: "789", reason: "No longer needed")

        assert result.success?
        assert_equal "denied", result.status
      end

      test "refill request for unknown transmission fails" do
        result = @service.request_refill("nonexistent-id", pharmacy_ncpdpid: "1234567")

        assert_not result.success?
      end

      # =========================================================================
      # CHANGE REQUESTS
      # =========================================================================

      test "request_change creates a pending change" do
        result = @service.request_change(
          @tx.transmission_id,
          pharmacy_ncpdpid: "1234567",
          new_medication: { code: "197885", display: "Lisinopril 20 MG" }
        )

        assert result.success?
        assert_equal "pending", result.status
      end

      test "approve_change changes status to approved" do
        change = @service.request_change(
          @tx.transmission_id,
          pharmacy_ncpdpid: "1234567",
          new_medication: { code: "197885", display: "Lisinopril 20 MG" }
        )
        result = @service.approve_change(change.transmission_id, provider_duz: "789")

        assert result.success?
        assert_equal "approved", result.status
      end

      test "deny_change changes status to denied" do
        change = @service.request_change(
          @tx.transmission_id,
          pharmacy_ncpdpid: "1234567",
          new_medication: { code: "197885", display: "Lisinopril 20 MG" }
        )
        result = @service.deny_change(change.transmission_id, provider_duz: "789", reason: "Not appropriate")

        assert result.success?
        assert_equal "denied", result.status
      end

      test "change request for unknown transmission fails" do
        result = @service.request_change(
          "nonexistent-id",
          pharmacy_ncpdpid: "1234567",
          new_medication: { code: "197885", display: "Lisinopril 20 MG" }
        )

        assert_not result.success?
      end

      private

      def build_signed_order
        MedicationRequest.new(
          ien: "med-#{SecureRandom.hex(4)}",
          patient_dfn: "12345",
          requester_duz: "789",
          medication_display: "Lisinopril 10 MG Oral Tablet",
          medication_code: "197884",
          status: "active",
          intent: "order",
          dosage_instruction: "Take 1 tablet daily",
          route: "oral",
          frequency: "daily",
          dispense_quantity: 30,
          refills: 3,
          days_supply: 30,
          authored_on: Time.current
        )
      end
    end
  end
end
