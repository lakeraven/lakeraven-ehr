# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AmendmentServiceTest < ActiveSupport::TestCase
      setup do
        AmendmentRequest.delete_all
        AuditEvent.delete_all
      end

      # =============================================================================
      # REQUEST CREATION
      # =============================================================================

      test "creates amendment request" do
        amendment = AmendmentService.request(
          patient_dfn: "12345",
          resource_type: "AllergyIntolerance",
          description: "Change penicillin to amoxicillin",
          reason: "Incorrect medication name"
        )

        assert amendment.persisted?
        assert amendment.pending?
        assert_equal "12345", amendment.patient_dfn
        assert_equal "AllergyIntolerance", amendment.resource_type
        assert_equal "Change penicillin to amoxicillin", amendment.description
      end

      test "creates audit event on request" do
        assert_difference "AuditEvent.count", 1 do
          AmendmentService.request(
            patient_dfn: "12345",
            resource_type: "Condition",
            description: "Remove incorrect diagnosis",
            reason: "Never diagnosed"
          )
        end
      end

      test "sets requested_by to patient_dfn by default" do
        amendment = AmendmentService.request(
          patient_dfn: "12345",
          resource_type: "Condition",
          description: "Remove diagnosis",
          reason: "Incorrect"
        )

        assert_equal "12345", amendment.requested_by
      end

      test "allows custom requested_by" do
        amendment = AmendmentService.request(
          patient_dfn: "12345",
          resource_type: "Condition",
          description: "Remove diagnosis",
          reason: "Incorrect",
          requested_by: "proxy-67890"
        )

        assert_equal "proxy-67890", amendment.requested_by
      end

      # =============================================================================
      # ACCEPT
      # =============================================================================

      test "accept updates status and creates audit" do
        amendment = create_pending_amendment

        assert_difference "AuditEvent.count", 1 do
          AmendmentService.accept(amendment, reviewer_duz: "789", reason: "Verified")
        end

        assert amendment.accepted?
        assert_equal "789", amendment.reviewed_by
      end

      # =============================================================================
      # DENY
      # =============================================================================

      test "deny updates status and creates audit" do
        amendment = create_pending_amendment

        assert_difference "AuditEvent.count", 1 do
          AmendmentService.deny(amendment, reviewer_duz: "789", reason: "Record is accurate")
        end

        assert amendment.denied?
        assert_equal "789", amendment.reviewed_by
      end

      test "deny requires reason" do
        amendment = create_pending_amendment

        assert_raises(ActiveRecord::RecordInvalid) do
          AmendmentService.deny(amendment, reviewer_duz: "789", reason: "")
        end
      end

      # =============================================================================
      # HISTORY
      # =============================================================================

      test "history returns amendments for patient in reverse chronological order" do
        3.times do |i|
          AmendmentService.request(
            patient_dfn: "12345",
            resource_type: "Condition",
            description: "Amendment #{i}",
            reason: "Reason #{i}"
          )
        end

        AmendmentService.request(
          patient_dfn: "99999",
          resource_type: "Observation",
          description: "Other patient",
          reason: "Other reason"
        )

        history = AmendmentService.history("12345")
        assert_equal 3, history.count
        assert history.first.created_at >= history.last.created_at
      end

      # =============================================================================
      # PENDING REVIEWS
      # =============================================================================

      test "pending_reviews returns only pending amendments" do
        a1 = create_pending_amendment
        a2 = create_pending_amendment
        a3 = create_pending_amendment
        a3.accept!(reviewer_duz: "789")

        pending = AmendmentService.pending_reviews
        assert_equal 2, pending.count
        assert pending.all?(&:pending?)
      end

      private

      def create_pending_amendment
        AmendmentService.request(
          patient_dfn: "12345",
          resource_type: "AllergyIntolerance",
          description: "Test amendment",
          reason: "Test reason"
        )
      end
    end
  end
end
