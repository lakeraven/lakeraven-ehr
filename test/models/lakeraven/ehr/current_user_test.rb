# frozen_string_literal: true

require "test_helper"

module Lakeraven
  module EHR
    class CurrentUserTest < ActiveSupport::TestCase
      # =============================================================================
      # BASIC INITIALIZATION
      # =============================================================================

      test "initializes with auth result hash" do
        user = build_user(user_type: "provider", duz: 123, name: "Test Provider")

        assert_equal 123, user.duz
        assert_equal "Test Provider", user.name
        assert_equal "provider", user.user_type
      end

      test "defaults to user type when not specified" do
        user = CurrentUser.new(duz: 123, name: "Test")
        assert_equal "user", user.user_type
      end

      # =============================================================================
      # ROLE CHECKS
      # =============================================================================

      test "provider? returns true for provider user type" do
        user = build_user(user_type: "provider")
        assert user.provider?
      end

      test "nurse? returns true for nurse user type" do
        user = build_user(user_type: "nurse")
        assert user.nurse?
      end

      test "clerk? returns true for clerk user type" do
        user = build_user(user_type: "clerk")
        assert user.clerk?
      end

      test "case_manager? returns true for case_manager user type" do
        user = build_user(user_type: "case_manager")
        assert user.case_manager?
      end

      test "case_manager? returns true for user with prc_manager key" do
        user = build_user(user_type: "clerk", security_keys: [ :prc_manager ])
        assert user.case_manager?
      end

      # =============================================================================
      # ROLE PERMISSIONS (can? method)
      # =============================================================================

      test "provider can view_patients" do
        user = build_user(user_type: "provider")
        assert user.can?(:view_patients)
      end

      test "provider can create_referrals" do
        user = build_user(user_type: "provider")
        assert user.can?(:create_referrals)
      end

      test "nurse can view_referrals" do
        user = build_user(user_type: "nurse")
        assert user.can?(:view_referrals)
      end

      test "clerk cannot create_referrals" do
        user = build_user(user_type: "clerk")
        refute user.can?(:create_referrals)
      end

      test "case_manager can approve_referrals" do
        user = build_user(user_type: "case_manager")
        assert user.can?(:approve_referrals)
      end

      test "user can only view_own_referrals" do
        user = build_user(user_type: "user")
        assert user.can?(:view_own_referrals)
        refute user.can?(:view_patients)
      end

      # =============================================================================
      # CHS-SPECIFIC PERMISSIONS
      # =============================================================================

      test "can_approve_chs? requires prc_supervisor or prc_manager key" do
        user_with_supervisor = build_user(user_type: "clerk", security_keys: [ :prc_supervisor ])
        user_with_manager = build_user(user_type: "clerk", security_keys: [ :prc_manager ])
        user_without_key = build_user(user_type: "case_manager", security_keys: [])

        assert user_with_supervisor.can_approve_chs?
        assert user_with_manager.can_approve_chs?
        refute user_without_key.can_approve_chs?
      end

      test "can_process_chs? requires prc_tech or prc_supervisor key" do
        user_with_tech = build_user(user_type: "clerk", security_keys: [ :prc_tech ])
        user_with_supervisor = build_user(user_type: "clerk", security_keys: [ :prc_supervisor ])
        user_without_key = build_user(user_type: "clerk", security_keys: [])

        assert user_with_tech.can_process_chs?
        assert user_with_supervisor.can_process_chs?
        refute user_without_key.can_process_chs?
      end

      test "can_manage_consults? requires consult_manager key" do
        user_with_key = build_user(user_type: "provider", security_keys: [ :consult_manager ])
        user_without_key = build_user(user_type: "provider", security_keys: [])

        assert user_with_key.can_manage_consults?
        refute user_without_key.can_manage_consults?
      end

      # =============================================================================
      # CAPABILITIES (aggregated permissions)
      # =============================================================================

      test "capabilities includes role permissions" do
        user = build_user(user_type: "provider")
        caps = user.capabilities

        assert caps.include?(:view_patients)
        assert caps.include?(:create_referrals)
        assert caps.include?(:view_referrals)
      end

      test "capabilities includes key-derived approve_referrals permission" do
        user = build_user(user_type: "clerk", security_keys: [ :prc_supervisor ])
        caps = user.capabilities

        assert caps.include?(:approve_referrals)
        assert caps.include?(:deny_referrals)
      end

      test "capabilities includes key-derived process_claims permission" do
        user = build_user(user_type: "clerk", security_keys: [ :prc_tech ])
        caps = user.capabilities

        assert caps.include?(:process_claims)
      end

      test "capabilities includes verify_eligibility for eligibility key" do
        user = build_user(user_type: "clerk", security_keys: [ :eligibility_verify ])
        caps = user.capabilities

        assert caps.include?(:verify_eligibility)
      end

      test "capabilities includes manage_consults for consult manager" do
        user = build_user(user_type: "provider", security_keys: [ :consult_manager ])
        caps = user.capabilities

        assert caps.include?(:manage_consults)
      end

      test "capabilities includes manage_scheduling for scheduling admin" do
        user = build_user(user_type: "clerk", security_keys: [ :scheduling_admin ])
        caps = user.capabilities

        assert caps.include?(:manage_scheduling)
      end

      test "capabilities includes access_behavioral_health for BH providers" do
        user = build_user(user_type: "provider", security_keys: [ :bh_provider ])
        caps = user.capabilities

        assert caps.include?(:access_behavioral_health)
      end

      test "capabilities includes access_dental for dental providers" do
        user = build_user(user_type: "provider", security_keys: [ :dental_provider ])
        caps = user.capabilities

        assert caps.include?(:access_dental)
      end

      private

      def build_user(user_type:, duz: 999, name: "TEST,USER", security_keys: [])
        CurrentUser.new(duz: duz, name: name, user_type: user_type, security_keys: security_keys)
      end
    end
  end
end
