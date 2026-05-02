# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class AmendmentRequestTest < ActiveSupport::TestCase
      setup do
        @amendment = AmendmentRequest.create!(
          patient_dfn: "1", resource_type: "Condition", requested_by: "301",
          description: "Incorrect diagnosis", reason: "Diagnosis was entered for wrong patient"
        )
      end

      # =============================================================================
      # CREATION & DEFAULTS
      # =============================================================================

      test "creates a valid amendment request" do
        assert @amendment.persisted?
        assert @amendment.pending?
      end

      test "defaults to pending status" do
        assert_equal "pending", @amendment.status
      end

      # =============================================================================
      # VALIDATIONS
      # =============================================================================

      test "requires patient_dfn" do
        ar = AmendmentRequest.new(resource_type: "Condition", description: "x", reason: "y", requested_by: "301")
        refute ar.valid?
        assert ar.errors[:patient_dfn].any?
      end

      test "requires resource_type" do
        ar = AmendmentRequest.new(patient_dfn: "1", description: "x", reason: "y", requested_by: "301")
        refute ar.valid?
        assert ar.errors[:resource_type].any?
      end

      test "requires description" do
        ar = AmendmentRequest.new(patient_dfn: "1", resource_type: "Condition", reason: "y", requested_by: "301")
        refute ar.valid?
        assert ar.errors[:description].any?
      end

      test "requires reason" do
        ar = AmendmentRequest.new(patient_dfn: "1", resource_type: "Condition", description: "x", requested_by: "301")
        refute ar.valid?
        assert ar.errors[:reason].any?
      end

      # =============================================================================
      # STATUS TRANSITIONS
      # =============================================================================

      test "accept! changes status to accepted" do
        @amendment.accept!(reviewer_duz: "302")

        assert @amendment.accepted?
        assert_equal "302", @amendment.reviewed_by
        refute_nil @amendment.reviewed_at
      end

      test "deny! changes status to denied with reason" do
        @amendment.deny!(reviewer_duz: "302", reason: "Diagnosis is correct per clinical review")

        assert @amendment.denied?
        assert_equal "302", @amendment.reviewed_by
        assert_equal "Diagnosis is correct per clinical review", @amendment.review_reason
      end

      test "deny! requires review_reason" do
        assert_raises(ActiveRecord::RecordInvalid) do
          @amendment.deny!(reviewer_duz: "302", reason: "")
        end
      end

      test "accept! raises if already reviewed" do
        @amendment.accept!(reviewer_duz: "302")

        assert_raises(RuntimeError) do
          @amendment.accept!(reviewer_duz: "303")
        end
      end

      test "deny! raises if already reviewed" do
        @amendment.deny!(reviewer_duz: "302", reason: "Correct")

        assert_raises(RuntimeError) do
          @amendment.deny!(reviewer_duz: "303", reason: "Also correct")
        end
      end

      # =============================================================================
      # SCOPES
      # =============================================================================

      test "for_patient scope filters by patient_dfn" do
        AmendmentRequest.create!(patient_dfn: "999", resource_type: "Condition",
                                  description: "x", reason: "y", requested_by: "301")

        assert_equal 1, AmendmentRequest.for_patient("1").count
      end

      test "pending_review scope returns only pending" do
        @amendment.accept!(reviewer_duz: "302")
        AmendmentRequest.create!(patient_dfn: "1", resource_type: "Condition",
                                  description: "x", reason: "y", requested_by: "301")

        assert_equal 1, AmendmentRequest.pending_review.count
      end

      # =============================================================================
      # PREDICATES
      # =============================================================================

      test "reviewed? returns true for accepted" do
        @amendment.accept!(reviewer_duz: "302")
        assert @amendment.reviewed?
      end

      test "reviewed? returns true for denied" do
        @amendment.deny!(reviewer_duz: "302", reason: "Correct")
        assert @amendment.reviewed?
      end

      test "reviewed? returns false for pending" do
        refute @amendment.reviewed?
      end
    end
  end
end
