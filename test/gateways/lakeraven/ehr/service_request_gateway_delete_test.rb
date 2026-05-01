# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class ServiceRequestGatewayDeleteTest < ActiveSupport::TestCase
      # =============================================================================
      # DELETE DRAFT REFERRALS
      # =============================================================================

      test "delete removes draft referral" do
        result = ServiceRequestGateway.delete("SR-DRAFT-001")

        assert result[:success]
      end

      test "delete returns referral IEN on success" do
        result = ServiceRequestGateway.delete("SR-DRAFT-001")

        assert result[:success]
        assert_equal "SR-DRAFT-001", result[:ien]
      end

      # =============================================================================
      # DELETE PENDING REFERRALS
      # =============================================================================

      test "delete pending referral requires reason" do
        result = ServiceRequestGateway.delete("SR-PENDING-001")

        refute result[:success]
        assert_includes result[:error].downcase, "reason"
      end

      test "delete pending referral with reason succeeds" do
        result = ServiceRequestGateway.delete("SR-PENDING-001", reason: "Entered in error")

        assert result[:success]
      end

      # =============================================================================
      # CANNOT DELETE AUTHORIZED/COMPLETED
      # =============================================================================

      test "delete authorized referral fails" do
        result = ServiceRequestGateway.delete("SR-AUTHORIZED-001")

        refute result[:success]
        assert_includes result[:error].downcase, "cannot delete"
      end

      # =============================================================================
      # CANCEL
      # =============================================================================

      test "cancel authorized referral with reason succeeds" do
        result = ServiceRequestGateway.cancel("SR-AUTHORIZED-001", reason: "Patient withdrew")

        assert result[:success]
      end

      test "cancel requires reason" do
        result = ServiceRequestGateway.cancel("SR-AUTHORIZED-001")

        refute result[:success]
        assert_includes result[:error].downcase, "reason"
      end

      # =============================================================================
      # ERROR HANDLING
      # =============================================================================

      test "delete nonexistent referral fails" do
        result = ServiceRequestGateway.delete("NONEXISTENT")

        refute result[:success]
      end

      # =============================================================================
      # DELETABLE STATUS CHECK
      # =============================================================================

      test "deletable? returns true for draft" do
        assert ServiceRequestGateway.deletable?("SR-DRAFT-001")
      end

      test "deletable? returns false for authorized" do
        refute ServiceRequestGateway.deletable?("SR-AUTHORIZED-001")
      end
    end
  end
end
